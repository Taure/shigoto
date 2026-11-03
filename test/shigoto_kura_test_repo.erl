-module(shigoto_kura_test_repo).
-behaviour(kura_repo).

-export([otp_app/0, transaction/1, insert/1]).

otp_app() -> shigoto.

transaction(Fun) ->
    kura_repo_worker:transaction(?MODULE, Fun).

insert(Changeset) ->
    kura_repo_worker:insert(?MODULE, Changeset).
