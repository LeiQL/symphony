/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package model

import (
	"errors"
	"time"
)

type (
	VersionedTargetStatus struct {
		Properties         map[string]string  `json:"properties,omitempty"`
		ProvisioningStatus ProvisioningStatus `json:"provisioningStatus"`
		LastModified       time.Time          `json:"lastModified,omitempty"`
	}
	// VersionedTargetState defines the current state of the target
	VersionedTargetState struct {
		ObjectMeta ObjectMeta            `json:"metadata,omitempty"`
		Status     VersionedTargetStatus `json:"status,omitempty"`
		Spec       *VersionedTargetSpec  `json:"spec,omitempty"`
	}

	// VersionedTargetSpec defines the spec property of the VersionedTargetState
	VersionedTargetSpec struct {
		DisplayName string `json:"displayName,omitempty"`
	}
)

func (c VersionedTargetSpec) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(VersionedTargetSpec)
	if !ok {
		return false, errors.New("parameter is not a VersionedTargetSpec type")
	}

	if c.DisplayName != otherC.DisplayName {
		return false, nil
	}

	return true, nil
}

func (c VersionedTargetState) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(VersionedTargetState)
	if !ok {
		return false, errors.New("parameter is not a VersionedTargetState type")
	}

	equal, err := c.ObjectMeta.DeepEquals(otherC.ObjectMeta)
	if err != nil || !equal {
		return equal, err
	}

	equal, err = c.Spec.DeepEquals(*otherC.Spec)
	if err != nil || !equal {
		return equal, err
	}

	return true, nil
}
