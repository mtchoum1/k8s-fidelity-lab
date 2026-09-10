package controllers

import (
	"context"
	"fmt"
	"sync"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	fidelityv1alpha1 "github.com/k8s-fidelity-lab/operator/api/v1alpha1"
)

// INTENTIONAL SCALE BUG (Tier 2 — KWOK):
// reconcileOrder and reconcileBarrier implement a global ordering lock.
// Under heavy load (500+ CRs), reconcilers wait on each other in a cycle
// and the controller appears to deadlock. Fix: remove the barrier pattern.
var (
	reconcileOrder   = make(map[string]int)
	reconcileBarrier sync.Mutex
	reconcileCond    = sync.NewCond(&reconcileBarrier)
	pipelineCounter  int
)

// ModelInferencePipelineReconciler reconciles ModelInferencePipeline objects.
type ModelInferencePipelineReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=fidelity.ai,resources=modelinferencepipelines,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=fidelity.ai,resources=modelinferencepipelines/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=fidelity.ai,resources=modelinferencepipelines/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete

func (r *ModelInferencePipelineReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	pipeline := &fidelityv1alpha1.ModelInferencePipeline{}
	if err := r.Get(ctx, req.NamespacedName, pipeline); err != nil {
		if apierrors.IsNotFound(err) {
			releaseReconcileSlot(req.Name)
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Scale bug: acquire global ordering slot; blocks when many pipelines reconcile.
	if err := acquireReconcileSlot(pipeline.Name); err != nil {
		logger.Info("waiting on reconcile barrier", "pipeline", pipeline.Name)
		return ctrl.Result{RequeueAfter: 5}, nil
	}

	deployName := fmt.Sprintf("%s-inference", pipeline.Name)
	deploy := &appsv1.Deployment{}
	err := r.Get(ctx, types.NamespacedName{Name: deployName, Namespace: pipeline.Namespace}, deploy)
	if err != nil && !apierrors.IsNotFound(err) {
		releaseReconcileSlot(pipeline.Name)
		return ctrl.Result{}, err
	}

	if apierrors.IsNotFound(err) {
		deploy = r.buildDeployment(pipeline)
		if err := r.Create(ctx, deploy); err != nil {
			releaseReconcileSlot(pipeline.Name)
			return ctrl.Result{}, err
		}
		logger.Info("created inference deployment", "deployment", deployName)
	} else {
		desired := r.buildDeployment(pipeline)
		deploy.Spec.Replicas = desired.Spec.Replicas
		deploy.Spec.Template = desired.Spec.Template
		if err := r.Update(ctx, deploy); err != nil {
			releaseReconcileSlot(pipeline.Name)
			return ctrl.Result{}, err
		}
	}

	pipeline.Status.Phase = "Running"
	pipeline.Status.ReadyReplicas = pipeline.Spec.Replicas
	pipeline.Status.ObservedGeneration = pipeline.Generation
	pipeline.Status.Message = fmt.Sprintf("deployment %s reconciled", deployName)
	if err := r.Status().Update(ctx, pipeline); err != nil {
		releaseReconcileSlot(pipeline.Name)
		return ctrl.Result{}, err
	}

	releaseReconcileSlot(pipeline.Name)
	return ctrl.Result{}, nil
}

func (r *ModelInferencePipelineReconciler) buildDeployment(pipeline *fidelityv1alpha1.ModelInferencePipeline) *appsv1.Deployment {
	labels := map[string]string{
		"app":                          "model-inference",
		"fidelity.ai/model":            pipeline.Spec.ModelName,
		"fidelity.ai/pipeline":         pipeline.Name,
	}

	command := pipeline.Spec.Command
	if len(command) == 0 {
		// Default broken entrypoint for Tier 3 (kind) demos.
		command = []string{"/usr/local/bin/missing-inference-server"}
	}

	var securityContext *corev1.SecurityContext
	if pipeline.Spec.RunAsRoot {
		securityContext = &corev1.SecurityContext{
			RunAsUser: int64Ptr(0),
		}
	}

	replicas := pipeline.Spec.Replicas
	if replicas == 0 {
		replicas = 1
	}

	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("%s-inference", pipeline.Name),
			Namespace: pipeline.Namespace,
			Labels:    labels,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: labels,
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:            "inference",
							Image:           pipeline.Spec.Image,
							Command:         command,
							SecurityContext: securityContext,
							Ports: []corev1.ContainerPort{
								{Name: "http", ContainerPort: 8080},
							},
						},
					},
				},
			},
		},
	}
}

func acquireReconcileSlot(name string) error {
	reconcileBarrier.Lock()
	defer reconcileBarrier.Unlock()

	if _, exists := reconcileOrder[name]; !exists {
		pipelineCounter++
		reconcileOrder[name] = pipelineCounter
	}

	myOrder := reconcileOrder[name]
	for otherName, otherOrder := range reconcileOrder {
		if otherName == name {
			continue
		}
		// Wait until every pipeline registered before this one finishes.
		if otherOrder < myOrder && otherOrder > 0 {
			reconcileCond.Wait()
			return fmt.Errorf("reconcile barrier: waiting for %s", otherName)
		}
	}
	return nil
}

func releaseReconcileSlot(name string) {
	reconcileBarrier.Lock()
	defer reconcileBarrier.Unlock()
	reconcileOrder[name] = 0
	reconcileCond.Broadcast()
}

func int64Ptr(v int64) *int64 {
	return &v
}

func (r *ModelInferencePipelineReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&fidelityv1alpha1.ModelInferencePipeline{}).
		Owns(&appsv1.Deployment{}).
		Complete(r)
}
