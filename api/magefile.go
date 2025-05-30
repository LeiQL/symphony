//go:build mage

/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package main

import (
	"fmt"
	"os"

	//mage:import
	_ "github.com/eclipse-symphony/symphony/packages/mage"
	"github.com/princjef/mageutil/shellcmd"
)

func Build() error {
	cargoBuildCmd := "cargo build --release --manifest-path pkg/apis/v1alpha1/providers/target/rust/Cargo.toml"
	goBuildCmd := "go build -o bin/symphony-api"
	if err := shellcmd.RunAll(
		shellcmd.Command(cargoBuildCmd),
		shellcmd.Command(goBuildCmd),
	); err != nil {
		return err
	}
	return nil
}

// Runs both api unit tests as well as coa unit tests.
func TestWithCoa() error {
	// Unit tests for api
	testHelper()

	// Change directory to coa
	os.Chdir("../coa")

	// Unit tests for coa
	testHelper()
	return nil
}

func raceCheckSkipped() bool {
	return os.Getenv("SKIP_RACE_CHECK") == "true"
}

func raceOpt() string {
	if raceCheckSkipped() {
		return ""
	}
	return "-race"
}

func testHelper() error {
	testClean := "go clean -testcache"
	testCmd := fmt.Sprintf("go test %s -timeout 5m -cover -coverprofile=coverage.out ./...", raceOpt())
	if err := shellcmd.RunAll(
		shellcmd.Command(testClean),
		shellcmd.Command(testCmd),
	); err != nil {
		return err
	}
	return nil
}
