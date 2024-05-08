/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package model

import (
	"errors"
)

type CampaignContainerState struct {
	ObjectMeta ObjectMeta             `json:"metadata,omitempty"`
	Spec       *CampaignContainerSpec `json:"spec,omitempty"`
}

type CampaignContainerSpec struct {
	Name string `json:"name,omitempty"`
}

func (c CampaignContainerSpec) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(CampaignContainerSpec)
	if !ok {
		return false, errors.New("parameter is not a CampaignContainerSpec type")
	}

	if c.Name != otherC.Name {
		return false, nil
	}

	return true, nil
}

func (c CampaignContainerState) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(CampaignContainerState)
	if !ok {
		return false, errors.New("parameter is not a CampaignContainerState type")
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
