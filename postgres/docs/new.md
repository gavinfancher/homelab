

making a new database and role for a new project


connect to db with `pgcli` as superuser `postgres`
```
pgcli -h postgres.ad.gavinf.com -U postgres
```

create the user with desired name as `<role_name>` and setting a password
```
create role <role_name> login '<password_here>';
```
- `<role_name>` is the desired role name
- `<role_password>` is the desired role password

creat the database
```
create database <db_name> owner <db_owner_role_name>;
revoke connect on database <db_name> from public;
grant connect on database <db_name> to <db_owner_role_name>;
```
- `<db_name>` is the desired database name
- `<db_owner_role_name>` is the specific role that you would like to own the database

the `revoke connect` command remvoes it from the public schema so that only the superuser can see/edit it. the `grant connect` command allows specified roles to see/edit the database.