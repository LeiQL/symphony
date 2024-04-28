/*
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT license.
 * SPDX-License-Identifier: MIT
 */

package solution

import (
	"context"
	"encoding/json"

	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"

	solutionv1 "gopls-workspace/apis/solution/v1"

	api_utils "github.com/eclipse-symphony/symphony/api/pkg/apis/v1alpha1/utils"
)

// SolutionReconciler reconciles a Solution object
type SolutionReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

//+kubebuilder:rbac:groups=solution.symphony,resources=solutions,verbs=get;list;watch;create;update;patch;delete
//+kubebuilder:rbac:groups=solution.symphony,resources=solutions/status,verbs=get;update;patch
//+kubebuilder:rbac:groups=solution.symphony,resources=solutions/finalizers,verbs=update

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
// TODO(user): Modify the Reconcile function to compare the state specified by
// the Solution object against the actual cluster state, and then
// perform operations to make the cluster state reflect the state specified by
// the user.
//
// For more details, check Reconcile and its Result here:
// - https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.11.0/pkg/reconcile
func (r *SolutionReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := ctrllog.FromContext(ctx)
	log.Info("Reconcile Solution")

	// Get instance
	solution := &solutionv1.Solution{}
	if err := r.Client.Get(ctx, req.NamespacedName, solution); err != nil {
		log.Error(err, "unable to fetch Solution object")
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if solution.Status.Properties == nil {
		solution.Status.Properties = make(map[string]string)
	}

	version := solution.Spec.Version
	name := solution.Spec.RootResource
	solutionName := name + ":" + version
	jData, _ := json.Marshal(solution)
	if solution.ObjectMeta.DeletionTimestamp.IsZero() { // update
		err := api_utils.UpsertSolution(ctx, "http://symphony-service:8080/v1alpha2/", solutionName, "admin", "", jData, req.Namespace)
		if err != nil {
			return ctrl.Result{}, err
		}
	} else { // delete
		err := api_utils.DeleteSolution(ctx, "http://symphony-service:8080/v1alpha2/", solutionName, "admin", "", req.Namespace)
		if err != nil {
			return ctrl.Result{}, err
		}
	}

	return ctrl.Result{}, nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *SolutionReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&solutionv1.Solution{}).
		Complete(r)
}
