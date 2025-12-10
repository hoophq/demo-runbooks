kubectl scale deployment {{ .deployment_name | options "busybox" }} --replicas={{ .num_replicas | options "1" "2" "3" }}
