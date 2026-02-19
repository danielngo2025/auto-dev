#!/usr/bin/env bats

@test "config template exists" {
  [ -f templates/config.yaml ]
}

@test "config template has required top-level keys" {
  run yq '.project' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.workflow' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.spec' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.app_runner' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.reviewer' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run yq '.summary' templates/config.yaml
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "config template has sensible defaults" {
  run yq '.workflow.max_rounds' templates/config.yaml
  [ "$output" = "3" ]

  run yq '.workflow.dev_agents' templates/config.yaml
  [ "$output" = "1" ]

  run yq '.workflow.branch_prefix' templates/config.yaml
  [ "$output" = "auto-dev/" ]

  run yq '.summary.refresh_interval' templates/config.yaml
  [ "$output" = "5" ]
}
