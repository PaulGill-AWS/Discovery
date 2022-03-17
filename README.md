# Discovery
Database Source Discovery Scripts in T-SQL.

Run this directly from SQL Management Studio whilst connected to the instance.
This can be run against a query group to gather multiple instances at the same time.

The script will output multiple result sets.

1. SQL Version Description and Instance Collation.
2. List of all databases with database collation, high availability configuration, replication, encryption status as well as data and log sizes.
3. Details of the server including domain name, high availability configuration, Windows Version and Edition, as well as the core SQL components installed.
4. A list of all users\groups present on the sql server and the core system roles they may have.
5. A list of all SQL agent jobs
6. A list of any SQL agent jobs utilising SSIS subsystem
