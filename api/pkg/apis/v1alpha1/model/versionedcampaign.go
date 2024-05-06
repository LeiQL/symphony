/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package model

import (
	"errors"
)

type VersionedCampaignState struct {
	ObjectMeta ObjectMeta             `json:"metadata,omitempty"`
	Spec       *VersionedCampaignSpec `json:"spec,omitempty"`
}

type VersionedCampaignSpec struct {
	Name string `json:"name,omitempty"`
}

func (c VersionedCampaignSpec) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(VersionedCampaignSpec)
	if !ok {
		return false, errors.New("parameter is not a VersionedCampaignSpec type")
	}

	if c.Name != otherC.Name {
		return false, nil
	}

	return true, nil
}

func (c VersionedCampaignState) DeepEquals(other IDeepEquals) (bool, error) {
	otherC, ok := other.(VersionedCampaignState)
	if !ok {
		return false, errors.New("parameter is not a VersionedCampaignState type")
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
