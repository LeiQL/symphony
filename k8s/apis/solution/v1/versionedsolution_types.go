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

type VersionedSolutionStatus struct {
	Properties         map[string]string           `json:"properties"`
	ProvisioningStatus apimodel.ProvisioningStatus `json:"provisioningStatus"`
	LastModified       metav1.Time                 `json:"lastModified,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// VersionedSolution is the Schema for the VersionedSolution API
type VersionedSolution struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   k8smodel.VersionedSolutionSpec `json:"spec,omitempty"`
	Status VersionedSolutionStatus        `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
// VersionedSolutionList contains a list of VersionedSolution
type VersionedSolutionList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VersionedSolution `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VersionedSolution{}, &VersionedSolutionList{})
}
