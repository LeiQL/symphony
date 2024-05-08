/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package model

import (
	"errors"
)

type SolutionContainerState struct {
	ObjectMeta ObjectMeta             `json:"metadata,omitempty"`
	Spec       *SolutionContainerSpec `json:"spec,omitempty"`
}

type SolutionContainerSpec struct {
	Name string `json:"name,omitempty"`
}

func (c SolutionContainerSpec) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(SolutionContainerSpec)
	if !ok {
		return false, errors.New("parameter is not a SolutionContainerSpec type")
	}

	if c.Name != otherC.Name {
		return false, nil
	}

	return true, nil
}

func (c SolutionContainerState) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(SolutionContainerState)
	if !ok {
		return false, errors.New("parameter is not a SolutionContainerState type")
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
