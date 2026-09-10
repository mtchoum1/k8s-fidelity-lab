package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ModelInferencePipelineSpec defines the desired state of a model inference pipeline.
type ModelInferencePipelineSpec struct {
	// ModelName is the KServe / ODH model identifier.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	ModelName string `json:"modelName"`

	// Replicas is the number of inference pods to run.
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=1000
	Replicas int32 `json:"replicas"`

	// Image is the container image for the inference server.
	// +kubebuilder:validation:Required
	Image string `json:"image"`

	// INTENTIONAL SCHEMA BUG (Tier 1 — envtest):
	// OpenAPI type is declared as string but the Go field is int32.
	// controller-gen emits a CRD that rejects integer values at admission time.
	// Fix: remove the Type=string marker or change the Go type to string.
	// +kubebuilder:validation:Type=string
	GPUCount int32 `json:"gpuCount,omitempty"`

	// RunAsRoot requests root UID 0 for the inference container.
	// INTENTIONAL OPENSHIFT BUG (Tier 7): violates restricted-v2 SCC.
	// Fix: set runAsRoot: false and add a non-root SecurityContext.
	// +optional
	RunAsRoot bool `json:"runAsRoot,omitempty"`

	// Command overrides the container entrypoint.
	// INTENTIONAL RUNTIME BUG (Tier 3 — kind): default sample uses a missing binary.
	// +optional
	Command []string `json:"command,omitempty"`
}

// ModelInferencePipelineStatus defines the observed state.
type ModelInferencePipelineStatus struct {
	Phase             string `json:"phase,omitempty"`
	Message           string `json:"message,omitempty"`
	ReadyReplicas     int32  `json:"readyReplicas,omitempty"`
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=mip
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
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
