%% Copyright (c) 2013-2014 Krzysztof Rutka
%%
%% Permission is hereby granted, free of charge, to any person obtaining a
%% copy of this software and associated documentation files (the "Software"),
%% to deal in the Software without restriction, including without limitation
%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%% and/or sell copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
%% IN THE SOFTWARE.

-module(erlcql_decode).

-export([new_parser/1]).
-export([parse/3]).
-export([decode/3]).

-include("erlcql.hrl").

-define(STRING(Length), Length/bytes).
-define(BYTES(Length), Length/bytes).

-spec new_parser(version()) -> parser().
new_parser(Version) ->
    #parser{version = Version}.

-spec parse(binary(), parser(), compression()) ->
          {ok, Responses :: [{Stream :: integer(),
                              Response :: response()}],
           NewParser :: parser()} |
          {error, Reason :: term()}.
parse(Data, #parser{buffer = Buffer} = Parser, Compression) ->
    NewBuffer = <<Buffer/binary, Data/binary>>,
    NewParser = Parser#parser{buffer = NewBuffer},
    parse_loop(NewParser, Compression, []).

-spec parse_loop(parser(), compression(), [{integer(), response()}]) ->
          {ok, Responses :: [{Stream :: integer(),
                              Response :: response()}],
           NewParser :: parser()} |
          {error, Reason :: term()}.
parse_loop(Parser, Compression, Responses) ->
    case run_parser(Parser, Compression) of
        {ok, Response, NewParser} ->
            parse_loop(NewParser, Compression, [Response | Responses]);
        {error, binary_too_small, NewParser} ->
            {ok, lists:reverse(Responses), NewParser};
        {error, Other} ->
            {error, Other}
    end.

run_parser(#parser{buffer = Buffer} = Parser, Compression) ->
    Size = byte_size(Buffer),
    case Size < 8 of
        true -> {error, binary_too_small, Parser};
        false ->
            #parser{length = Length} = NewParser = get_length(Parser),
            case Size < Length of
                true ->
                    {error, binary_too_small, NewParser};
                false ->
                    run_decode(NewParser, Compression)
            end
    end.

get_length(#parser{length = undefined, buffer = Buffer} = Parser) ->
    <<_:32, Length:32, _/binary>> = Buffer,
    Parser#parser{length = Length + 8};
get_length(Parser) -> Parser.

run_decode(#parser{version = Version,
                   buffer = Buffer} = Parser, Compression) ->
    case decode(Version, Buffer, Compression) of
        {ok, Stream, Response, Leftovers} ->
            NewParser = Parser#parser{length = undefined,
                                      buffer = Leftovers},
            {ok, {Stream, Response}, NewParser};
        {error, Other} ->
            {error, Other}
    end.

-spec decode(version(), binary(), compression()) ->
          {ok, Stream :: integer(), Response :: response(), Rest :: binary()} |
          {error, Reason :: term()}.
decode(V, <<?RESPONSE:1, V:7, _Flags:7, Decompress:1,
            Stream:8/signed, Opcode:8, Length:32, Data:Length/binary,
            Rest/binary>>, Compression) ->
    Data2 = maybe_decompress(Decompress, Compression, Data),
    Response = case opcode(Opcode) of
                   cql_error ->
                       cql_error(Data2);
                   ready ->
                       ready(Data2);
                   authenticate ->
                       authenticate(Data2);
                   supported ->
                       supported(Data2);
                   result ->
                       result(Data2);
                   event ->
                       event(Data2);
                   auth_challenge ->
                       auth_challenge(Data2);
                   auth_success ->
                       auth_success(Data2)
               end,
    {ok, Stream, Response, Rest};
decode(_V, <<_Other:32, Length:32, _Data:Length/binary,
             _Rest/binary>>, _Compression) ->
    {error, bad_header};
decode(_V, _Other, _Compression) ->
    {error, binary_too_small}.

-spec maybe_decompress(0 | 1, compression(), binary()) -> binary().
maybe_decompress(0, _Compression, Data) ->
    Data;
maybe_decompress(1, snappy, Data) ->
    {ok, DecompressedData} = snappy:decompress(Data),
    DecompressedData;
maybe_decompress(1, lz4, <<Size:32, Data/binary>>) ->
    {ok, UnpackedData} = lz4:uncompress(Data, Size),
    UnpackedData.

-spec opcode(integer()) -> response_opcode().
opcode(16#00) -> cql_error;
opcode(16#02) -> ready;
opcode(16#03) -> authenticate;
opcode(16#06) -> supported;
opcode(16#08) -> result;
opcode(16#0c) -> event;
opcode(16#0e) -> auth_challenge;
opcode(16#10) -> auth_success.

-spec cql_error(binary()) -> cql_error().
cql_error(<<ErrorCode:?INT, Data/binary>>) ->
    Error = case error_code(ErrorCode) of
                unavailable_exception ->
                    unavailable_exception(Data);
                write_timeout ->
                    write_timeout(Data);
                read_timeout ->
                    read_timeout(Data);
                already_exists ->
                    already_exists(Data);
                unprepared ->
                    unprepared(Data);
                Other ->
                    other_error(Other, Data)
            end,
    {Code, Message, Extra} = Error,
    ?ERROR("Error message from Cassandra: ~s \"~s\"", [Code, Message]),
    {error, {Code, Message, Extra}}.

-spec error_code(integer()) -> error_code().
error_code(16#0000) -> server_error;
error_code(16#000a) -> protocol_error;
error_code(16#0100) -> bad_credentials;
error_code(16#1000) -> unavailable_exception;
error_code(16#1001) -> overloaded;
error_code(16#1002) -> is_bootstapping;
error_code(16#1003) -> truncate_error;
error_code(16#1100) -> write_timeout;
error_code(16#1200) -> read_timeout;
error_code(16#2000) -> syntax_error;
error_code(16#2100) -> unauthorized;
error_code(16#2200) -> invalid;
error_code(16#2300) -> config_error;
error_code(16#2400) -> already_exists;
error_code(16#2500) -> unprepared.

-spec unavailable_exception(binary()) ->
          {unavailable_exception, Message :: bitstring(),
           {Consistency :: consistency(),
            Required :: integer(), Alive :: integer()}}.
unavailable_exception(<<Length:?SHORT, Message:Length/binary,
                        Consistency:?SHORT, Required:?INT, Alive:?INT>>) ->
    {unavailable_exception, Message, {consistency(Consistency),
                                      Required, Alive}}.

-spec write_timeout(binary()) ->
          {write_timeout, Message :: bitstring(),
           {Consistency :: consistency(), Received :: integer(),
            Blockfor :: integer(), WriteType :: bitstring()}}.
write_timeout(<<Length:?SHORT, Message:Length/binary,
                Consistency:?SHORT, Received:?INT, Blockfor:?INT,
                Length2:?SHORT, WriteType:Length2/binary>>) ->
    {write_timeout, Message, {consistency(Consistency),
                              Received, Blockfor, WriteType}}.

-spec read_timeout(binary()) ->
          {read_timeout, Message :: bitstring(),
           {Consistency :: consistency(), Received :: integer(),
            Blockfor :: integer(), DataPresent :: boolean()}}.
read_timeout(<<Length:?SHORT, Message:Length/binary, Consistency:?SHORT,
               Received:?INT, Blockfor:?INT, PresentByte:8>>) ->
    Present = PresentByte == 0,
    {read_timeout, Message, {consistency(Consistency),
                             Received, Blockfor, Present}}.

-spec already_exists(binary()) ->
          {already_exists, Message :: bitstring(),
           {Keyspace :: bitstring(), Table :: bitstring()}}.
already_exists(<<Length:?SHORT, Message:Length/binary,
                 Length2:?SHORT, Keyspace:Length2/binary,
                 Length3:?SHORT, Table:Length3/binary>>) ->
    {already_exists, Message, {Keyspace, Table}}.

-spec unprepared(binary()) ->
          {unprepared, Message :: bitstring(), QueryId :: uuid()}.
unprepared(<<Length:?SHORT, Message:Length/binary,
             Length2:?SHORT, QueryId:Length2/binary>>) ->
    {unprepared, Message, QueryId}.

-spec other_error(error_code(), binary()) ->
          {Code :: error_code(), Message :: bitstring(), undefined}.
other_error(ErrorCode, <<Length:?SHORT, Message:Length/binary>>) ->
    {ErrorCode, Message, undefined}.

-spec consistency(integer()) -> consistency().
consistency(0) -> any;
consistency(1) -> one;
consistency(2) -> two;
consistency(3) -> three;
consistency(4) -> quorum;
consistency(5) -> all;
consistency(6) -> local_quorum;
consistency(7) -> each_quorum.

-spec ready(binary()) -> ready.
ready(<<>>) ->
    ready.

-spec authenticate(binary()) -> authenticate().
authenticate(<<Length:?SHORT, AuthClass:?STRING(Length)>>) ->
    {authenticate, AuthClass}.

-spec supported(binary()) -> supported().
supported(<<N:?SHORT, Data/binary>>) ->
    Supported = supported_map(N, Data, []),
    {ok, Supported}.

-spec supported_map(integer(), binary(), [{binary(), [binary()]}]) ->
          Map :: [{binary(), [binary()]}].
supported_map(0, <<>>, Map) ->
    lists:reverse(Map);
supported_map(N, <<Length:?SHORT, Key:Length/binary,
                   M:?SHORT, Data/binary>>, Map) ->
    {Values, Rest} = supported_list(M, Data, []),
    supported_map(N - 1, Rest, [{Key, Values} | Map]).

-spec supported_list(integer(), binary(), [binary()]) ->
          {List :: [binary()], Rest :: binary()}.
supported_list(0, Rest, Values) ->
    {lists:reverse(Values), Rest};
supported_list(N, <<Length:?SHORT, Value:Length/binary,
                    Rest/binary>>, Values) ->
    supported_list(N - 1, Rest, [Value | Values]).

-spec result(binary()) -> result().
result(<<Kind:?INT, Data/binary>>) ->
    case result_kind(Kind) of
        void ->
            void(Data);
        rows ->
            rows(Data);
        set_keyspace ->
            set_keyspace(Data);
        prepared ->
            prepared(Data);
        schema_change ->
            schema_change(Data)
    end.

-spec result_kind(integer()) -> result_kind().
result_kind(16#0001) -> void;
result_kind(16#0002) -> rows;
result_kind(16#0003) -> set_keyspace;
result_kind(16#0004) -> prepared;
result_kind(16#0005) -> schema_change.

-spec void(binary()) -> void().
void(<<>>) ->
    {ok, void}.

-spec rows(binary()) -> rows().
rows(Data) ->
    {ColumnCount, Metadata, RowData} = metadata(Data),
    <<RowCount:?INT, RowContent/binary>> = RowData,
    Types = proplists:get_value(types, Metadata),
    Rows = rows(RowCount, ColumnCount, Types, RowContent, []),
    {ok, {Rows, Metadata}}.

-spec metadata(binary()) -> {integer(), column_specs(), Rest :: binary()}.
metadata(<<_:29, NoMetadata:1, HasMorePages:1, GlobalSpec:1,
           ColumnCount:?INT, Rest/binary>>) ->
    {Params2, Rest2} = maybe_more_pages(HasMorePages, [], Rest),
    {Params3, Rest3} = maybe_global_spec(GlobalSpec, Params2, Rest2),
    {Params4, Rest4} = maybe_column_spec(NoMetadata, GlobalSpec,
                                         ColumnCount, Params3, Rest3),
    {ColumnCount, Params4, Rest4}.

maybe_more_pages(0, Params, Data) -> {Params, Data};
maybe_more_pages(1, Params, Data) ->
    <<Length:?INT, PagingState:?BYTES(Length), Rest/binary>> = Data,
    {[{paging_state, PagingState} | Params], Rest}.

maybe_global_spec(0, Params, Data) -> {Params, Data};
maybe_global_spec(1, Params, Data) ->
    <<Length:?SHORT, Keyspace:?STRING(Length),
      Length2:?SHORT, Table:?STRING(Length2), Rest/binary>> = Data,
    {[{keyspace, Keyspace}, {table, Table} | Params], Rest}.

maybe_column_spec(1, _, 0, Params, Data) -> {Params, Data};
maybe_column_spec(0, Global, N, Params, Data) ->
    {Columns, Types, Rest} = column_specs(Global == 1, N, Data, [], []),
    {[{columns, Columns}, {types, Types} | Params], Rest}.

-spec column_specs(boolean(), integer(), binary(), column_specs(), term()) ->
          {column_specs(), Rest :: binary()}.
column_specs(_, 0, Rest, Columns, Types) ->
    {lists:reverse(Columns), lists:reverse(Types), Rest};
column_specs(true, N, <<Length:?SHORT, Column:?STRING(Length), TypeData/binary>>,
             Columns, Types) ->
    {Type, Rest} = option(TypeData),
    column_specs(true, N - 1, Rest, [Column | Columns], [Type | Types]);
column_specs(false, N, <<Length:?SHORT, _Keyspace:?STRING(Length),
                         Length2:?SHORT, _Table:?STRING(Length2),
                         Length3:?SHORT, Column:?STRING(Length3),
                         TypeData/binary>>,
             Columns, Types) ->
    {Type, Rest} = option(TypeData),
    column_specs(false, N - 1, Rest, [Column | Columns], [Type | Types]).

-spec option(binary()) -> {option(), Rest :: binary()}.
option(<<Id:?SHORT, Data/binary>>) ->
    case option_id(Id) of
        custom ->
            custom_option(Data);
        list ->
            {Type, Rest} = option(Data),
            {{list, Type}, Rest};
        map ->
            {KeyType, Rest} = option(Data),
            {ValueType, Rest2} = option(Rest),
            {{map, KeyType, ValueType}, Rest2};
        set ->
            {Type, Rest} = option(Data),
            {{set, Type}, Rest};
        OptionId ->
            {OptionId, Data}
    end.

-spec custom_option(binary()) -> {option(), Rest :: binary()}.
custom_option(<<Length:?SHORT, Value:?STRING(Length), Rest/binary>>) ->
    {{custom, Value}, Rest}.

-spec option_id(integer()) -> option_id().
option_id(16#0000) -> custom;
option_id(16#0001) -> ascii;
option_id(16#0002) -> bigint;
option_id(16#0003) -> blob;
option_id(16#0004) -> boolean;
option_id(16#0005) -> counter;
option_id(16#0006) -> decimal;
option_id(16#0007) -> double;
option_id(16#0008) -> float;
option_id(16#0009) -> int;
option_id(16#000a) -> text;
option_id(16#000b) -> timestamp;
option_id(16#000c) -> uuid;
option_id(16#000d) -> varchar;
option_id(16#000e) -> varint;
option_id(16#000f) -> timeuuid;
option_id(16#0010) -> inet;
option_id(16#0020) -> list;
option_id(16#0021) -> map;
option_id(16#0022) -> set.

-spec rows(integer(), integer(), [option()], binary(), [[binary()]]) ->
          Rows :: [[binary()]].
rows(0, _N, _Types, <<>>, Rows) ->
    lists:reverse(Rows);
rows(M, N, Types, Data, Rows) ->
    {Values, Rest} = row_values(N, Types, Data, []),
    rows(M - 1, N, Types, Rest, [Values | Rows]).

-spec row_values(integer(), [option()], binary(), [binary()]) ->
          {Values :: [binary()], Rest :: binary()}.
row_values(0, [], Rest, Values) ->
    {lists:reverse(Values), Rest};
row_values(N, [Type | Types], <<-1:?INT, Rest/binary>>, Values) ->
    Value = erlcql_convert:from_null(Type),
    row_values(N - 1, Types, Rest, [Value | Values]);
row_values(N, [Type | Types], <<Length:?INT, Value:Length/binary,
                                Rest/binary>>, Values) ->
    Value2 = erlcql_convert:from_binary(Type, Value),
    row_values(N - 1, Types, Rest, [Value2 | Values]).

-spec set_keyspace(binary()) -> set_keyspace().
set_keyspace(<<Length:?SHORT, Keyspace:Length/binary>>) ->
    {ok, Keyspace}.

-spec prepared(binary()) -> {ok, bitstring(), [option()]}.
prepared(<<Length:?SHORT, QueryId:Length/binary, Data/binary>>) ->
    {_ColumnCount, RequestMetadata, Rest} = metadata(Data),
    {_, ResultMetadata, <<>>} = metadata(Rest),
    {ok, {QueryId, RequestMetadata, ResultMetadata}}.

-spec schema_change(binary()) -> schema_change().
schema_change(<<Length:?SHORT, Type:Length/binary,
                Length2:?SHORT, _Keyspace:Length2/binary,
                Length3:?SHORT, _Table:Length3/binary>>) ->
    {ok, schema_change_type(Type)}.

-spec event(binary()) -> event_res().
event(<<Length:?SHORT, Type:?STRING(Length), Data/binary>>) ->
    Event = case event_type(Type) of
                topology_change ->
                    topology_change_event(Data);
                status_change ->
                    status_change_event(Data);
                schema_change ->
                    schema_change_event(Data)
            end,
    {event, Event}.

-spec event_type(bitstring()) -> event_type().
event_type(<<"TOPOLOGY_CHANGE">>) -> topology_change;
event_type(<<"STATUS_CHANGE">>)   -> status_change;
event_type(<<"SCHEMA_CHANGE">>)   -> schema_change.

-spec topology_change_event(binary()) ->
          {topology_change, Type :: atom(), Inet :: inet()}.
topology_change_event(<<Length:?SHORT, Type:?STRING(Length), Data/binary>>) ->
    {topology_change, topology_change_type(Type), inet(Data)}.

-spec topology_change_type(bitstring()) -> atom().
topology_change_type(<<"NEW_NODE">>)     -> new_node;
topology_change_type(<<"REMOVED_NODE">>) -> removed_node.

-spec status_change_event(binary()) ->
          {status_change, Type :: atom(), Inet :: inet()}.
status_change_event(<<Length:?SHORT, Type:?STRING(Length), Data/binary>>) ->
    {status_change, status_change_type(Type), inet(Data)}.

-spec status_change_type(bitstring()) -> atom().
status_change_type(<<"UP">>)   -> up;
status_change_type(<<"DOWN">>) -> down.

-spec schema_change_event(binary()) ->
          {schema_change, Type :: atom(),
           {Keyspace :: bitstring(), Table :: bitstring()}}.
schema_change_event(<<Length:?SHORT, Type:?STRING(Length),
                      Length2:?SHORT, Keyspace:?STRING(Length2),
                      Length3:?SHORT, Table:?STRING(Length3)>>) ->
    {schema_change, schema_change_type(Type), {Keyspace, Table}}.

-spec schema_change_type(bitstring()) -> atom().
schema_change_type(<<"CREATED">>) -> created;
schema_change_type(<<"UPDATED">>) -> updated;
schema_change_type(<<"DROPPED">>) -> dropped.

-spec inet(binary()) -> inet().
inet(<<Size:8, Data/binary>>) ->
    inet(Size, Data).

-spec inet(4 | 16, binary()) -> inet().
inet(4, <<A:8, B:8, C:8, D:8, Port:?INT>>) ->
    {{A, B, C, D}, Port};
inet(16, <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16, Port:?INT>>) ->
    {{A, B, C, D, E, F, G, H}, Port}.

-spec auth_challenge(binary()) -> {auth_challenge, binary()}.
auth_challenge(<<Length:?INT, Token:Length/binary>>) ->
    {auth_challenge, Token}.

-spec auth_success(binary()) -> {auth_success, binary()}.
auth_success(<<Length:?INT, Token:Length/binary>>) ->
    {auth_success, Token}.
