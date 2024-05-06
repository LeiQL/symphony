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

type VersionedCatalogStatus struct {
	Properties         map[string]string           `json:"properties"`
	ProvisioningStatus apimodel.ProvisioningStatus `json:"provisioningStatus"`
	LastModified       metav1.Time                 `json:"lastModified,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// VersionedCatalog is the Schema for the catalogs API
type VersionedCatalog struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   k8smodel.VersionedCatalogSpec `json:"spec,omitempty"`
	Status VersionedCatalogStatus        `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
// VersionedCatalogList contains a list of Catalog
type VersionedCatalogList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VersionedCatalog `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VersionedCatalog{}, &VersionedCatalogList{})
}
