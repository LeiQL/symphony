/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package model

import (
	"errors"
)

// TODO: all state objects should converge to this paradigm: id, spec and status
type CatalogContainerState struct {
	ObjectMeta ObjectMeta            `json:"metadata,omitempty"`
	Spec       *CatalogContainerSpec `json:"spec,omitempty"`
}

type CatalogContainerSpec struct {
	Name string `json:"name"`
}

func (c CatalogContainerSpec) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(CatalogContainerSpec)
	if !ok {
		return false, errors.New("parameter is not a CatalogContainerSpec type")
	}

	if c.Name != otherC.Name {
		return false, nil
	}

	return true, nil
}

func (c CatalogContainerState) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(CatalogContainerState)
	if !ok {
		return false, errors.New("parameter is not a CatalogContainerState type")
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
