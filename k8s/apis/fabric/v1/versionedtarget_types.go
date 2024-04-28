/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package v1

import (
	apimodel "github.com/eclipse-symphony/symphony/api/pkg/apis/v1alpha1/model"
	k8smodel "github.com/eclipse-symphony/symphony/k8s/apis/model/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VersionedTargetStatus defines the observed state of Target
type VersionedTargetStatus struct {
	// Important: Run "make" to regenerate code after modifying this file
	Properties         map[string]string           `json:"properties,omitempty"`
	ProvisioningStatus apimodel.ProvisioningStatus `json:"provisioningStatus"`
	LastModified       metav1.Time                 `json:"lastModified,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Status",type=string,JSONPath=`.status.properties.status`
// Target is the Schema for the targets API
type VersionedTarget struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   k8smodel.VersionedTargetSpec `json:"spec,omitempty"`
	Status VersionedTargetStatus        `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
// TargetList contains a list of Target
type VersionedTargetList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VersionedTarget `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VersionedTarget{}, &VersionedTargetList{})
}
