SELECT *
FROM orders as o
LEFT JOIN users as u
ON o.user_id = u.user_id
WHERE u.email = {{ .email | type "select" | description "Pick a user" | options "john.doe@example.com jane.smith@example.com" }}
;
