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

type VersionedInstanceStatus struct {
	Properties         map[string]string           `json:"properties"`
	ProvisioningStatus apimodel.ProvisioningStatus `json:"provisioningStatus"`
	LastModified       metav1.Time                 `json:"lastModified,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// VersionedInstance1 is the Schema for the versionedinstances API
type VersionedInstance struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   k8smodel.VersionedInstanceSpec `json:"spec,omitempty"`
	Status VersionedInstanceStatus        `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
// VersionedInstance1List contains a list of VersionedInstance
type VersionedInstanceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VersionedInstance `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VersionedInstance{}, &VersionedInstanceList{})
}