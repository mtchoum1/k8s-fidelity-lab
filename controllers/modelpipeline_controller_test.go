package controllers

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"

	fidelityv1alpha1 "github.com/k8s-fidelity-lab/operator/api/v1alpha1"
)

var _ = Describe("PR #104 ModelInferencePipeline Controller", func() {
	const (
		timeout  = "30s"
		interval = "500ms"
	)

	Context("Tier 1 — CRD schema validation", func() {
		It("Should accept a CR that includes gpuMemoryRequirement (PR #104)", func() {
			ctx := context.Background()
			name := "pr104-valid"
			namespace := "default"

			pipeline := &fidelityv1alpha1.ModelInferencePipeline{
				ObjectMeta: metav1.ObjectMeta{
					Name:      name,
					Namespace: namespace,
				},
				Spec: fidelityv1alpha1.ModelInferencePipelineSpec{
					ModelName:            "sklearn-iris",
					Replicas:             1,
					Image:                "ghcr.io/k8s-fidelity-lab/inference-server:latest",
					GPUMemoryRequirement: "16Gi",
					SidecarLogging:       true,
				},
			}

			Expect(k8sClient.Create(ctx, pipeline)).Should(Succeed())

			created := &fidelityv1alpha1.ModelInferencePipeline{}
			Eventually(func() error {
				return k8sClient.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, created)
			}, timeout, interval).Should(Succeed())

			Expect(created.Spec.GPUMemoryRequirement).To(Equal("16Gi"))
			Expect(created.Spec.SidecarLogging).To(BeTrue())
		})

		It("Should reject CRs missing gpuMemoryRequirement (Tier 1 — missing +optional)", func() {
			ctx := context.Background()

			// Use unstructured so gpuMemoryRequirement is absent from JSON (Go client would send "").
			pipeline := &unstructured.Unstructured{}
			pipeline.SetGroupVersionKind(schema.GroupVersionKind{
				Group:   "fidelity.ai",
				Version: "v1alpha1",
				Kind:    "ModelInferencePipeline",
			})
			pipeline.SetName("pr104-missing-gpu")
			pipeline.SetNamespace("default")
			pipeline.Object["spec"] = map[string]interface{}{
				"modelName":      "sklearn-iris",
				"replicas":       int64(1),
				"image":          "ghcr.io/k8s-fidelity-lab/inference-server:latest",
				"sidecarLogging": true,
			}

			err := k8sClient.Create(ctx, pipeline)
			Expect(err).To(HaveOccurred())
		})
	})

	Context("Tier 1 — controller nil-pointer guard", func() {
		It("Should panic when gpuMemoryRequirement is not in the scale map", func() {
			reconciler := &ModelInferencePipelineReconciler{}
			pipeline := &fidelityv1alpha1.ModelInferencePipeline{
				Spec: fidelityv1alpha1.ModelInferencePipelineSpec{
					ModelName:            "sklearn-iris",
					Replicas:             2,
					Image:                "ghcr.io/k8s-fidelity-lab/inference-server:latest",
					GPUMemoryRequirement: "8Gi",
					SidecarLogging:       true,
				},
			}

			Expect(func() {
				reconciler.buildDeployment(pipeline)
			}).To(Panic())
		})
	})
})
