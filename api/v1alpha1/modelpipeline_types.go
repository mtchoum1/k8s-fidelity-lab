package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ModelInferencePipelineSpec defines the desired state of a model inference pipeline.
// PR #104: feat: Add high-throughput GPU batch inference & metrics sidecar
type ModelInferencePipelineSpec struct {
	// ModelName is the KServe / ODH model identifier.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	ModelName string `json:"modelName"`

	// Replicas is the base number of inference pods to run.
	// The controller scales this dynamically when gpuMemoryRequirement is set.
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=1000
	Replicas int32 `json:"replicas"`

	// Image is the container image for the inference server.
	// +kubebuilder:validation:Required
	Image string `json:"image"`

	// GPUMemoryRequirement is the GPU memory allocation per replica (e.g. "16Gi").
	// PR #104 field — INTENTIONAL TIER 1 BUG: missing // +optional marker.
	// CRD admission rejects CRs that omit this field. Fix: add // +optional.
	// +kubebuilder:validation:MinLength=1
	GPUMemoryRequirement string `json:"gpuMemoryRequirement"`

	// SidecarLogging enables the metrics/logging sidecar injected by the controller.
	// +optional
	SidecarLogging bool `json:"sidecarLogging,omitempty"`

	// SidecarImage overrides the default metrics sidecar image.
	// +optional
	SidecarImage string `json:"sidecarImage,omitempty"`
}

// ModelInferencePipelineStatus defines the observed state.
type ModelInferencePipelineStatus struct {
	Phase              string `json:"phase,omitempty"`
	Message            string `json:"message,omitempty"`
	ReadyReplicas      int32  `json:"readyReplicas,omitempty"`
	ObservedGeneration int64  `json:"observedGeneration,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=mip
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="GPU Mem",type=string,JSONPath=`.spec.gpuMemoryRequirement`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type ModelInferencePipeline struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ModelInferencePipelineSpec   `json:"spec"`
	Status ModelInferencePipelineStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type ModelInferencePipelineList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ModelInferencePipeline `json:"items"`
}

func init() {
	SchemeBuilder.Register(&ModelInferencePipeline{}, &ModelInferencePipelineList{})
}
