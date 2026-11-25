

making a new database and role for a new project


connect to db with `pgcli`
```
pgcli -h postgres.ad.gavinf.com -U postgres
```

```
create role <role_name> login;
```
```
create database <db_name> owner <db_owner_role_name>;
```
```
alter role <role_name> password '<password_here>';
```