#!/bin/bash
# Test script for solution registry concurrent updates

# Source the solution registry manager
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/solution-registry-manager.sh"

# Function to simulate concurrent updates
test_concurrent_updates() {
  local category="testCategory"
  local base_solution="solution"
  local num_processes=5
  local solutions_per_process=10
  
  log "Testing concurrent updates with $num_processes processes, each adding $solutions_per_process solutions"
  
  # Initialize the registry
  init_solution_registry
  
  # Create a temp directory for process output
  tmp_dir=$(mktemp -d)
  
  # Start multiple processes that add solutions concurrently
  for i in $(seq 1 $num_processes); do
    (
      # Generate a unique set of solutions for this process
      for j in $(seq 1 $solutions_per_process); do
        solution_name="${base_solution}_${i}_${j}"
        add_solution "$category" "$solution_name"
        sleep 0.1  # Small delay to ensure some overlap
      done
      echo "Process $i completed"
    ) > "$tmp_dir/process_$i.log" 2>&1 &
  done
  
  # Wait for all processes to complete
  wait
  
  # Check the results
  log "All processes completed. Checking results..."
  
  # Expected total number of solutions
  expected_count=$((num_processes * solutions_per_process))
  
  # Get actual solutions
  solutions=$(list_solutions "$category")
  actual_count=$(echo "$solutions" | jq '. | length')
  
  # Display results
  log "Expected solutions: $expected_count"
  log "Actual solutions: $actual_count"
  
  if [ "$actual_count" -eq "$expected_count" ]; then
    log "SUCCESS: All solutions were added correctly"
  else
    log "FAILURE: Some solutions were lost due to concurrent update issues"
    
    # Analyze what's missing
    log "Checking which solutions are missing..."
    for i in $(seq 1 $num_processes); do
      for j in $(seq 1 $solutions_per_process); do
        solution_name="${base_solution}_${i}_${j}"
        if ! solution_exists "$category" "$solution_name"; then
          log "Missing: $solution_name"
        fi
      done
    done
  fi
  
  # Clean up
  rm -rf "$tmp_dir"
}

# Function to test removing items concurrently
test_concurrent_removals() {
  local category="testCategory"
  local base_solution="solution"
  local num_processes=3
  local solutions_per_process=5
  
  log "Testing concurrent removals with $num_processes processes"
  
  # Initialize the registry and add test solutions
  init_solution_registry
  
  # Add solutions first
  for i in $(seq 1 $num_processes); do
    for j in $(seq 1 $solutions_per_process); do
      solution_name="${base_solution}_${i}_${j}"
      add_solution "$category" "$solution_name"
    done
  done
  
  # Verify all solutions were added
  solutions=$(list_solutions "$category")
  initial_count=$(echo "$solutions" | jq '. | length')
  expected_initial=$((num_processes * solutions_per_process))
  
  log "Added $initial_count solutions (expected $expected_initial)"
  
  # Create a temp directory for process output
  tmp_dir=$(mktemp -d)
  
  # Start multiple processes that remove solutions concurrently
  for i in $(seq 1 $num_processes); do
    (
      # Remove the solutions for this process
      for j in $(seq 1 $solutions_per_process); do
        solution_name="${base_solution}_${i}_${j}"
        remove_solution "$category" "$solution_name"
        sleep 0.1  # Small delay to ensure some overlap
      done
      echo "Process $i completed"
    ) > "$tmp_dir/process_$i.log" 2>&1 &
  done
  
  # Wait for all processes to complete
  wait
  
  # Check the results
  log "All removal processes completed. Checking results..."
  
  # Get actual solutions
  solutions=$(list_solutions "$category")
  final_count=$(echo "$solutions" | jq '. | length')
  
  # Display results
  log "Expected remaining solutions: 0"
  log "Actual remaining solutions: $final_count"
  
  if [ "$final_count" -eq 0 ]; then
    log "SUCCESS: All solutions were removed correctly"
  else
    log "FAILURE: Some solutions were not removed"
    log "Remaining solutions:"
    echo "$solutions" | jq -r .
  fi
  
  # Clean up
  rm -rf "$tmp_dir"
}

# Function to test mixed operations (adds and removes concurrently)
test_mixed_operations() {
  local category="testCategory"
  local base_solution="solution"
  local num_add_processes=2
  local num_remove_processes=2
  local solutions_per_process=5
  
  log "Testing mixed operations (adds and removes concurrently)"
  
  # Initialize the registry
  init_solution_registry
  
  # Add some initial solutions for removal processes
  for i in $(seq 1 $num_remove_processes); do
    for j in $(seq 1 $solutions_per_process); do
      solution_name="${base_solution}_remove_${i}_${j}"
      add_solution "$category" "$solution_name"
    done
  done
  
  # Create a temp directory for process output
  tmp_dir=$(mktemp -d)
  
  # Start processes that add solutions concurrently
  for i in $(seq 1 $num_add_processes); do
    (
      # Add solutions
      for j in $(seq 1 $solutions_per_process); do
        solution_name="${base_solution}_add_${i}_${j}"
        add_solution "$category" "$solution_name"
        sleep 0.1  # Small delay to ensure some overlap
      done
      echo "Add process $i completed"
    ) > "$tmp_dir/add_process_$i.log" 2>&1 &
  done
  
  # Start processes that remove solutions concurrently
  for i in $(seq 1 $num_remove_processes); do
    (
      # Remove solutions
      for j in $(seq 1 $solutions_per_process); do
        solution_name="${base_solution}_remove_${i}_${j}"
        remove_solution "$category" "$solution_name"
        sleep 0.1  # Small delay to ensure some overlap
      done
      echo "Remove process $i completed"
    ) > "$tmp_dir/remove_process_$i.log" 2>&1 &
  done
  
  # Wait for all processes to complete
  wait
  
  # Check the results
  log "All mixed operation processes completed. Checking results..."
  
  # Get actual solutions
  solutions=$(list_solutions "$category")
  
  # Check add operations
  errors=0
  for i in $(seq 1 $num_add_processes); do
    for j in $(seq 1 $solutions_per_process); do
      solution_name="${base_solution}_add_${i}_${j}"
      if ! solution_exists "$category" "$solution_name"; then
        log "ERROR: Added solution '$solution_name' is missing"
        errors=$((errors + 1))
      fi
    done
  done
  
  # Check remove operations
  for i in $(seq 1 $num_remove_processes); do
    for j in $(seq 1 $solutions_per_process); do
      solution_name="${base_solution}_remove_${i}_${j}"
      if solution_exists "$category" "$solution_name"; then
        log "ERROR: Removed solution '$solution_name' still exists"
        errors=$((errors + 1))
      fi
    done
  done
  
  # Display results
  if [ $errors -eq 0 ]; then
    log "SUCCESS: All mixed operations were processed correctly"
  else
    log "FAILURE: $errors errors detected in mixed operations"
    log "Current solutions:"
    echo "$solutions" | jq -r .
  fi
  
  # Clean up
  rm -rf "$tmp_dir"
}

# Main function to run all tests
run_all_tests() {
  log "Starting all concurrent update tests"
  
  test_concurrent_updates
  test_concurrent_removals
  test_mixed_operations
  
  log "All tests completed"
}

# Run all tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_all_tests
fi
  
  log "Testing mixed operations (adds and removes concurrently)"
  
  # Initialize the registry
  init_solution_registry
  
  # Create a temp directory for process output
  tmp_dir=$(mktemp -d)
  
  # Add some initial solutions
  for i in $(seq 1 10); do
    add_solution "$category" "${base_solution}_${i}"
  done
  
  # Start a process that adds solutions
  (
    for i in $(seq 11 20); do
      add_solution "$category" "${base_solution}_${i}"
      sleep 0.1
    done
    echo "Add process completed"
  ) > "$tmp_dir/add_process.log" 2>&1 &
  
  # Start a process that removes solutions
  (
    for i in $(seq 1 5); do
      remove_solution "$category" "${base_solution}_${i}"
      sleep 0.15
    done
    echo "Remove process completed"
  ) > "$tmp_dir/remove_process.log" 2>&1 &
  
  # Wait for all processes to complete
  wait
  
  # Check the results
  log "All mixed processes completed. Checking results..."
  
  # Expected solutions: 10 initial + 10 added - 5 removed = 15
  expected_count=15
  
  # Get actual solutions
  solutions=$(list_solutions "$category")
  actual_count=$(echo "$solutions" | jq '. | length')
  
  # Display results
  log "Expected solutions: $expected_count"
  log "Actual solutions: $actual_count"
  
  if [ "$actual_count" -eq "$expected_count" ]; then
    log "SUCCESS: Mixed operations completed correctly"
  else
    log "FAILURE: Mixed operations resulted in incorrect state"
    log "Actual solutions:"
    echo "$solutions" | jq -r .
    
    # Check what's missing or unexpected
    log "Verifying solutions..."
    
    # These should be removed (1-5)
    for i in $(seq 1 5); do
      solution_name="${base_solution}_${i}"
      if solution_exists "$category" "$solution_name"; then
        log "ERROR: Solution $solution_name should have been removed but still exists"
      fi
    done
    
    # These should exist (6-20)
    for i in $(seq 6 20); do
      solution_name="${base_solution}_${i}"
      if ! solution_exists "$category" "$solution_name"; then
        log "ERROR: Solution $solution_name should exist but is missing"
      fi
    done
  fi
  
  # Clean up
  rm -rf "$tmp_dir"
}

# Run all tests
run_tests() {
  log "Starting concurrent update tests..."
  
  test_concurrent_updates
  log ""
  
  test_concurrent_removals
  log ""
  
  test_mixed_operations
  log ""
  
  log "All tests completed"
}

# If the script is run directly, execute the tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_tests
fi
