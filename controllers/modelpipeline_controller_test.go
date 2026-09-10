package controllers

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	fidelityv1alpha1 "github.com/k8s-fidelity-lab/operator/api/v1alpha1"
)

var _ = Describe("ModelInferencePipeline Controller", func() {
	const (
		timeout  = "30s"
		interval = "500ms"
	)

	Context("When creating a valid ModelInferencePipeline", func() {
		It("Should accept a CR with valid schema", func() {
			ctx := context.Background()
			name := "valid-pipeline"
			namespace := "default"

			pipeline := &fidelityv1alpha1.ModelInferencePipeline{
				ObjectMeta: metav1.ObjectMeta{
					Name:      name,
					Namespace: namespace,
				},
				Spec: fidelityv1alpha1.ModelInferencePipelineSpec{
					ModelName: "sklearn-iris",
					Replicas:  1,
					Image:     "ghcr.io/k8s-fidelity-lab/inference-server:latest",
					GPUCount:  0,
				},
			}

			Expect(k8sClient.Create(ctx, pipeline)).Should(Succeed())

			created := &fidelityv1alpha1.ModelInferencePipeline{}
			Eventually(func() error {
				return k8sClient.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, created)
			}, timeout, interval).Should(Succeed())

			Expect(created.Spec.ModelName).To(Equal("sklearn-iris"))
		})
	})

	Context("When creating a CR with schema violations", func() {
		It("Should reject gpuCount when passed as integer (Tier 1 schema bug)", func() {
			ctx := context.Background()

			// The CRD declares gpuCount as type=string but samples pass integers.
			// This test documents the schema mismatch caught by envtest.
			pipeline := &fidelityv1alpha1.ModelInferencePipeline{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "schema-bug-pipeline",
					Namespace: "default",
				},
				Spec: fidelityv1alpha1.ModelInferencePipelineSpec{
					ModelName: "broken-model",
					Replicas:  1,
					Image:     "ghcr.io/k8s-fidelity-lab/inference-server:latest",
					GPUCount:  2,
				},
			}

			err := k8sClient.Create(ctx, pipeline)
			// With the intentional schema bug, admission rejects integer gpuCount.
			Expect(err).To(HaveOccurred())
		})
	})
})
