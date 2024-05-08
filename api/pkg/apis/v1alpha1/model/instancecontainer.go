/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package model

import (
	"errors"
)

type InstanceContainerState struct {
	ObjectMeta ObjectMeta             `json:"metadata,omitempty"`
	Spec       *InstanceContainerSpec `json:"spec,omitempty"`
}

type InstanceContainerSpec struct {
	Name string `json:"name,omitempty"`
}

func (c InstanceContainerSpec) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(InstanceContainerSpec)
	if !ok {
		return false, errors.New("parameter is not a InstanceContainerSpec type")
	}

	if c.Name != otherC.Name {
		return false, nil
	}

	return true, nil
}

func (c InstanceContainerState) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(InstanceContainerState)
	if !ok {
		return false, errors.New("parameter is not a InstanceContainerState type")
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
