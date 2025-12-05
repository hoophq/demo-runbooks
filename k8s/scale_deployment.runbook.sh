scale deployment {{ .deployment_name | type "select" | description "Select a pre-approved deployment" | options "busybox" }} --replicas={{ .num_replicas }}
