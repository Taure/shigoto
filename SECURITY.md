# Security Policy

## Reporting a vulnerability

Report it privately through GitHub: on the repository's **Security** tab,
choose **Report a vulnerability**
(<https://github.com/Taure/shigoto/security/advisories/new>). Please do not
open a public issue or pull request for it.

Say what you can of: the version, what someone needs to be able to do (read
the jobs table, write to it, connect to the database, insert a job), what they
gain, and how to reproduce it.

You will get an answer in the advisory thread. A fix is released as a new
patch version and the advisory is published with it.

## Supported versions

The latest minor release of the current major version gets security fixes.

## What counts

The [Security guide](guides/security.md) says what shigoto protects, against
whom, and what it leaves to the application. Something that breaks a row of
its first table is a vulnerability. Something listed under "What is not
protected" is a known limit: an issue or a pull request is the place for it.
