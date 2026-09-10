package controllers

import (
	"context"
	"fmt"
	"sync"
	"time"

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

const (
	defaultSidecarImage = "ghcr.io/k8s-fidelity-lab/metrics-sidecar:latest"
)

// gpuScaleFactor maps GPU memory tiers to replica multipliers (PR #104 batch scaling).
type gpuScaleFactor struct {
	Multiplier int32
}

// INTENTIONAL TIER 1 BUG: unknown gpuMemoryRequirement values return nil and panic on dereference.
var gpuMemoryScaleFactors = map[string]*gpuScaleFactor{
	"16Gi": {Multiplier: 2},
	"32Gi": {Multiplier: 4},
}

// INTENTIONAL TIER 2 BUG (KWOK): global lock + sequential pod-status polling starves the worker pool.
var podStatusPollLock sync.Mutex

// ModelInferencePipelineReconciler reconciles ModelInferencePipeline objects.
type ModelInferencePipelineReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=fidelity.ai,resources=modelinferencepipelines,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=fidelity.ai,resources=modelinferencepipelines/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=fidelity.ai,resources=modelinferencepipelines/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete

func (r *ModelInferencePipelineReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	pipeline := &fidelityv1alpha1.ModelInferencePipeline{}
	if err := r.Get(ctx, req.NamespacedName, pipeline); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	deployName := fmt.Sprintf("%s-inference", pipeline.Name)
	deploy := &appsv1.Deployment{}
	err := r.Get(ctx, types.NamespacedName{Name: deployName, Namespace: pipeline.Namespace}, deploy)
	if err != nil && !apierrors.IsNotFound(err) {
		return ctrl.Result{}, err
	}

	if apierrors.IsNotFound(err) {
		deploy = r.buildDeployment(pipeline)
		if err := r.Create(ctx, deploy); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("created inference deployment", "deployment", deployName, "replicas", *deploy.Spec.Replicas)
	} else {
		desired := r.buildDeployment(pipeline)
		deploy.Spec.Replicas = desired.Spec.Replicas
		deploy.Spec.Template = desired.Spec.Template
		if err := r.Update(ctx, deploy); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Tier 2: blocks reconcile until every pod reports Running (sequential polling).
	if err := r.waitForPodStatuses(ctx, pipeline, deployName); err != nil {
		logger.Info("waiting on pod status updates", "pipeline", pipeline.Name, "error", err.Error())
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}

	pipeline.Status.Phase = "Running"
	pipeline.Status.ReadyReplicas = *deploy.Spec.Replicas
	pipeline.Status.ObservedGeneration = pipeline.Generation
	pipeline.Status.Message = fmt.Sprintf("deployment %s reconciled with sidecar=%v", deployName, pipeline.Spec.SidecarLogging)
	if err := r.Status().Update(ctx, pipeline); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

func (r *ModelInferencePipelineReconciler) buildDeployment(pipeline *fidelityv1alpha1.ModelInferencePipeline) *appsv1.Deployment {
	labels := map[string]string{
		"app":                  "model-inference",
		"fidelity.ai/model":    pipeline.Spec.ModelName,
		"fidelity.ai/pipeline": pipeline.Name,
	}

	replicas := r.computeReplicas(pipeline)

	containers := []corev1.Container{
		{
			Name:  "inference",
			Image: pipeline.Spec.Image,
			Command: []string{"python", "inference_server.py"},
			Ports: []corev1.ContainerPort{
				{Name: "http", ContainerPort: 8080},
			},
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{},
				Limits:   corev1.ResourceList{},
			},
		},
	}

	var volumes []corev1.Volume
	if pipeline.Spec.SidecarLogging {
		containers = append(containers, r.buildSidecarContainer(pipeline))
		// INTENTIONAL TIER 7 BUG: sidecar writes to hostPath /var/log as root.
		volumes = append(volumes, corev1.Volume{
			Name: "sidecar-logs",
			VolumeSource: corev1.VolumeSource{
				HostPath: &corev1.HostPathVolumeSource{
					Path: "/var/log",
					Type: hostPathPtr(corev1.HostPathDirectory),
				},
			},
		})
	}

	annotations := map[string]string{}
	if pipeline.Spec.SidecarLogging {
		annotations["serving.kserve.io/inferenceservice"] = pipeline.Spec.ModelName
		annotations["rhoai.redhat.com/gpu-batch"] = pipeline.Spec.GPUMemoryRequirement
	}

	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("%s-inference", pipeline.Name),
			Namespace: pipeline.Namespace,
			Labels:    labels,
			Annotations: annotations,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: labels,
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels:      labels,
					Annotations: annotations,
				},
				Spec: corev1.PodSpec{
					Containers: containers,
					Volumes:    volumes,
				},
			},
		},
	}
}

func (r *ModelInferencePipelineReconciler) buildSidecarContainer(pipeline *fidelityv1alpha1.ModelInferencePipeline) corev1.Container {
	image := pipeline.Spec.SidecarImage
	if image == "" {
		image = defaultSidecarImage
	}

	// INTENTIONAL TIER 3 BUG: SIDECAR_LOG_DIR is required by the sidecar entrypoint but not set here.
	// Fix: add Env var SIDECAR_LOG_DIR=/var/log/sidecar and switch Tier 7 volume to emptyDir.
	return corev1.Container{
		Name:  "metrics-sidecar",
		Image: image,
		Command: []string{"/usr/local/bin/sidecar-entrypoint.sh"},
		// INTENTIONAL TIER 7 BUG: root UID writes to /var/log — blocked by OpenShift restricted-v2 SCC.
		SecurityContext: &corev1.SecurityContext{
			RunAsUser: int64Ptr(0),
		},
		VolumeMounts: []corev1.VolumeMount{
			{Name: "sidecar-logs", MountPath: "/var/log"},
		},
		Ports: []corev1.ContainerPort{
			{Name: "metrics", ContainerPort: 9090},
		},
	}
}

func (r *ModelInferencePipelineReconciler) computeReplicas(pipeline *fidelityv1alpha1.ModelInferencePipeline) int32 {
	base := pipeline.Spec.Replicas
	if base == 0 {
		base = 1
	}

	// INTENTIONAL TIER 1 BUG: nil pointer when gpuMemoryRequirement is not in the scale map.
	scale := gpuMemoryScaleFactors[pipeline.Spec.GPUMemoryRequirement]
	return base * scale.Multiplier
}

func (r *ModelInferencePipelineReconciler) waitForPodStatuses(ctx context.Context, pipeline *fidelityv1alpha1.ModelInferencePipeline, deployName string) error {
	podStatusPollLock.Lock()
	defer podStatusPollLock.Unlock()

	podList := &corev1.PodList{}
	if err := r.List(ctx, podList, client.InNamespace(pipeline.Namespace), client.MatchingLabels{
		"fidelity.ai/pipeline": pipeline.Name,
	}); err != nil {
		return err
	}

	// Sequential poll: each pod must be Running before the next is checked.
	for _, item := range podList.Items {
		podName := types.NamespacedName{Name: item.Name, Namespace: item.Namespace}
		pod := &corev1.Pod{}
		for {
			if err := r.Get(ctx, podName, pod); err != nil {
				return err
			}
			if pod.Status.Phase == corev1.PodRunning {
				break
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			time.Sleep(2 * time.Second)
		}
	}
	return nil
}

func int64Ptr(v int64) *int64 {
	return &v
}

func hostPathPtr(t corev1.HostPathType) *corev1.HostPathType {
	return &t
}

func (r *ModelInferencePipelineReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&fidelityv1alpha1.ModelInferencePipeline{}).
		Owns(&appsv1.Deployment{}).
		Complete(r)
}
