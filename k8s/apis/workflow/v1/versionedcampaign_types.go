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

type VersionedCampagignStatus struct {
	Properties         map[string]string           `json:"properties"`
	ProvisioningStatus apimodel.ProvisioningStatus `json:"provisioningStatus"`
	LastModified       metav1.Time                 `json:"lastModified,omitempty"`
}

// +kubebuilder:object:root=true
// VersionedCampaign is the Schema for the campaigns API
type VersionedCampaign struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   k8smodel.VersionedCampaignSpec `json:"spec,omitempty"`
	Status VersionedCampagignStatus       `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
// VersionedCampaignList contains a list of Campaign
type VersionedCampaignList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VersionedCampaign `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VersionedCampaign{}, &VersionedCampaignList{})
}