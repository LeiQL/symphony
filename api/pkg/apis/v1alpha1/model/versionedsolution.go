/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package model

import (
	"errors"
)

type (
	VersionedSolutionState struct {
		ObjectMeta ObjectMeta             `json:"metadata,omitempty"`
		Spec       *VersionedSolutionSpec `json:"spec,omitempty"`
	}

	VersionedSolutionSpec struct {
		DisplayName string            `json:"displayName,omitempty"`
		Metadata    map[string]string `json:"metadata,omitempty"`
	}
)

func (c VersionedSolutionSpec) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(VersionedSolutionSpec)
	if !ok {
		return false, errors.New("parameter is not a VersionedSolutionSpec type")
	}

	if c.DisplayName != otherC.DisplayName {
		return false, nil
	}

	if !StringMapsEqual(c.Metadata, otherC.Metadata, nil) {
		return false, nil
	}

	return true, nil
}

func (c VersionedSolutionState) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(VersionedSolutionState)
	if !ok {
		return false, errors.New("parameter is not a VersionedSolutionState type")
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
