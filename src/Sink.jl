
type Sink <: Data.Sink
    schema::Data.Schema
    dsn::DSN
    table::String
end

# DataStreams interface
function Sink{T}(source, ::Type{T}, append::Bool, dsn::DSN, table::AbstractString)
    sink = Sink(Data.schema(source), dsn, table)
    !append && ODBC.execute!(dsn, "delete from $table")
    return sink
end
function Sink{T}(sink, source, ::Type{T}, append::Bool)
    !append && ODBC.execute!(sink.dsn, "delete from $(sink.table)")
    return sink
end

Data.streamtypes{T<:ODBC.Sink}(::Type{T}) = [Data.Column]

prep!{T}(::Type{T}, A) = A, 0
prep!{T}(::Type{Nullable{T}}, A) = A.values, 0
prep!(::Union{Type{Date},Type{Nullable{Date}}}, A) = ODBC.API.SQLDate[isnull(x) ? ODBC.API.SQLDate() : ODBC.API.SQLDate(x) for x in A], 0
prep!(::Union{Type{DateTime},Type{Nullable{DateTime}}}, A) = ODBC.API.SQLTimestamp[isnull(x) ? ODBC.API.SQLTimestamp() : ODBC.API.SQLTimestamp(x) for x in A], 0
if is_unix()
prep!(::Union{Type{Dec64},Type{Nullable{Dec64}}}, A) = Float64[isnull(x) ? 0.0 : Float64(get(x)) for x in A], 0
end

getptrlen(x::AbstractString) = pointer(x.data), length(x), UInt8[]
getptrlen{T}(x::WeakRefString{T}) = convert(Ptr{UInt8}, x.ptr), codeunits2bytes(T, x.len), UInt8[]
getptrlen{T}(x::Nullable{T}) = isnull(x) ? (convert(Ptr{UInt8}, C_NULL), 0, UInt8[]) : getptrlen(get(x))
function getptrlen(x::CategoricalArrays.CategoricalValue)
    ref = String(x).data
    return pointer(ref), length(ref), ref
end

prep!{T<:AbstractString}(::Type{T}, A) = _prep!(T, A)
prep!{T<:AbstractString}(::Type{Nullable{T}}, A) = _prep!(T, A)
prep!{T<:CategoricalArrays.CategoricalValue}(::Type{T}, A) = _prep!(T, A)
prep!{T<:CategoricalArrays.CategoricalValue}(::Type{Nullable{T}}, A) = _prep!(T, A)

function _prep!{T}(::Type{T}, column)
    maxlen = maximum(clength, column)
    maxlen = typeof(maxlen) <: Nullable ? get(maxlen) : maxlen
    data = zeros(UInt8, maxlen * length(column))
    ind = 1
    for i = 1:length(column)
        ptr, len, ref = getptrlen(column[i])
        unsafe_copy!(pointer(data, ind), ptr, len)
        ind += maxlen
    end
    return data, maxlen
end

function prep!{T}(source, ::Type{T}, col, columns, indcols)
    column = Data.getcolumn(source, T, col)
    columns[col], maxlen = prep!(T, column)
    indcols[col] = ODBC.API.SQLLEN[clength(x) for x in column]
    return length(column), maxlen
end

getCtype{T}(::Type{T}) = get(ODBC.API.julia2C, T, ODBC.API.SQL_C_CHAR)
getCtype{T}(::Type{Nullable{T}}) = get(ODBC.API.julia2C, T, ODBC.API.SQL_C_CHAR)

function Data.stream!(source, ::Type{Data.Column}, sink::ODBC.Sink, append::Bool=false)
    Data.types(source) == Data.types(sink) || throw(ArgumentError("schema mismatch: \n$(Data.schema(source))\nvs.\n$(Data.schema(sink))"))
    rows, cols = size(source)
    Data.isdone(source, 1, 1) && return sink
    stmt = sink.dsn.stmt_ptr2
    ODBC.execute!(sink.dsn, "select * from $(sink.table)", stmt)
    types = Data.types(source)
    columns = Vector{Any}(cols)
    indcols = Vector{Any}(cols)
    row = 0
    while !Data.isdone(source, row+1, cols)
        for col = 1:cols
            T = types[col]
            rows, len = prep!(source, T, col, columns, indcols)
            ODBC.@CHECK stmt ODBC.API.SQL_HANDLE_STMT ODBC.API.SQLBindCols(stmt, col, getCtype(T), columns[col], len, indcols[col])
        end
        ODBC.API.SQLSetStmtAttr(stmt, ODBC.API.SQL_ATTR_ROW_ARRAY_SIZE, rows, ODBC.API.SQL_IS_UINTEGER)
        ODBC.@CHECK stmt ODBC.API.SQL_HANDLE_STMT ODBC.API.SQLBulkOperations(stmt, ODBC.API.SQL_ADD)
        row += rows
    end
    Data.setrows!(source, row)
    return sink
end

function load{T}(dsn::DSN, table::AbstractString, ::Type{T}, args...; append::Bool=false)
    source = T(args...)
    sink = Sink(Data.schema(source), dsn, table)
    Data.stream!(source, sink, append)
    return sink
end
function load(dsn::DSN, table::AbstractString, source; append::Bool=false)
    sink = Sink(Data.schema(source), dsn, table)
    Data.stream!(source, sink, append)
    return sink
end

load{T}(sink::Sink, ::Type{T}, args...; append::Bool=false) = Data.stream!(T(args...), sink, append)
load(sink::Sink, source; append::Bool=false) = Data.stream!(source, sink, append)

# function Data.stream!(source, ::Type{Data.Column}, sink::ODBC.Sink, append::Bool=false)
#     Data.types(source) == Data.types(sink) || throw(ArgumentError("schema mismatch: \n$(Data.schema(source))\nvs.\n$(Data.schema(sink))"))
#     rows, cols = size(source)
#     Data.isdone(source, 1, 1) && return sink
#     ODBC.execute!(sink.dsn, "select * from $(sink.table)")
#     stmt = sink.dsn.stmt_ptr
#     types = Data.types(source)
#     columns = Vector{Any}(cols)
#     indcols = Array{Vector{ODBC.API.SQLLEN}}(cols)
#     row = 0
#     # get the column names for a table from the DB to generate the insert into sql statement
#     # might have to try quoting
#     # SQLPrepare (hdlStmt, (SQLTCHAR*)"INSERT INTO customers (CustID, CustName,  Phone_Number) VALUES(?,?,?)", SQL_NTS) ;
#     try
#         # SQLSetConnectAttr(hdlDbc, SQL_ATTR_AUTOCOMMIT, SQL_AUTOCOMMIT_OFF, SQL_NTS)
#         while !Data.isdone(source, row+1, cols+1)
#
#             for col = 1:cols
#                 T = types[col]
#                 # SQLBindParameter(hdlStmt, 1, SQL_PARAM_INPUT, SQL_C_LONG, SQL_INTEGER, 0, 0, (SQLPOINTER)custIDs, sizeof(SQLINTEGER) , NULL);
#                 rows, cT = ODBC.bindcolumn!(source, T, col, columns, indcols)
#                 ret = ODBC.API.SQLBindCols(stmt, col, cT, pointer(columns[col]), sizeof(eltype(columns[col])), indcols[col])
#                 println("$col: $ret")
#             end
#             ODBC.API.SQLSetStmtAttr(stmt, ODBC.API.SQL_ATTR_ROW_ARRAY_SIZE, rows, ODBC.API.SQL_IS_UINTEGER)
#             # SQLSetStmtAttr( hdlStmt, SQL_ATTR_PARAMSET_SIZE, (SQLPOINTER)NUM_ENTRIES, 0 );
#             # ret = SQLExecute(hdlStmt);
#             ODBC.@CHECK stmt ODBC.API.SQL_HANDLE_STMT ODBC.API.SQLBulkOperations(stmt, ODBC.API.SQL_ADD)
#             row += rows
#         end
#         # SQLEndTran(SQL_HANDLE_DBC, hdlDbc, SQL_COMMIT);
#     # finally
#         # SQLSetConnectAttr(hdlDbc, SQL_ATTR_AUTOCOMMIT, SQL_AUTOCOMMIT_ON, SQL_NTS);
#     end
#     Data.setrows!(source, row)
#     return sink
# end