SELECT *
FROM admin.users
WHERE user_id = {{ .user_id | type "number" }}
;
