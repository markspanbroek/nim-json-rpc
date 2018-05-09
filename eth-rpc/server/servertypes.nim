import asyncdispatch, asyncnet, json, tables, macros, strutils
export asyncdispatch, asyncnet, json

type
  RpcProc* = proc (params: JsonNode): Future[JsonNode]

  RpcServer* = ref object
    socket*: AsyncSocket
    port*: Port
    address*: string
    procs*: TableRef[string, RpcProc]

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  server.procs[name] = rpc

proc unRegisterAll*(server: RpcServer) = server.procs.clear

proc newRpcServer*(address = "localhost", port: Port = Port(8545)): RpcServer =
  result = RpcServer(
    socket: newAsyncSocket(),
    port: port,
    address: address,
    procs: newTable[string, RpcProc]()
  )

var sharedServer: RpcServer

proc sharedRpcServer*(): RpcServer =
  if sharedServer.isNil: sharedServer = newRpcServer("")
  result = sharedServer
  
proc fromJson(n: JsonNode, argName: string, result: var bool) =
  if n.kind != JBool: raise newException(ValueError, "Parameter \"" & argName & "\" expected JBool but got " & $n.kind)
  result = n.getBool()

proc fromJson(n: JsonNode, argName: string, result: var int) =
  if n.kind != JInt: raise newException(ValueError, "Parameter \"" & argName & "\" expected JInt but got " & $n.kind)
  result = n.getInt()

proc fromJson(n: JsonNode, argName: string, result: var byte) =
  if n.kind != JInt: raise newException(ValueError, "Parameter \"" & argName & "\" expected JInt but got " & $n.kind)
  let v = n.getInt()
  if v > 255 or v < 0: raise newException(ValueError, "Parameter \"" & argName & "\" value out of range for byte: " & $v)
  result = byte(v)

proc fromJson(n: JsonNode, argName: string, result: var float) =
  if n.kind != JFloat: raise newException(ValueError, "Parameter \"" & argName & "\" expected JFloat but got " & $n.kind)
  result = n.getFloat()

proc fromJson(n: JsonNode, argName: string, result: var string) =
  if n.kind != JString: raise newException(ValueError, "Parameter \"" & argName & "\" expected JString but got " & $n.kind)
  result = n.getStr()

proc fromJson[T](n: JsonNode, argName: string, result: var seq[T]) =
  result = newSeq[T](n.len)
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T]) =
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc fromJson[T: object](n: JsonNode, argName: string, result: var T) =
  for k, v in fieldpairs(result):
    fromJson(n[k], k, v)

proc unpackArg[T](argIdx: int, argName: string, argtype: typedesc[T], args: JsonNode): T =
  when argType is array or argType is seq:
    if args[argIdx].kind != JArray: raise newException(ValueError, "Parameter \"" & argName & "\" expected JArray but got " & $args[argIdx].kind)
  when argType is array:
    if args[argIdx].len > result.len: raise newException(ValueError, "Parameter \"" & argName & "\" item count is too big for array")
  when argType is object:
    if args[argIdx].kind != JObject: raise newException(ValueError, "Parameter \"" & argName & "\" expected JObject but got " & $args[argIdx].kind)
  fromJson(args[argIdx], argName, result)

proc expectArrayLen(node: NimNode, paramsIdent: untyped, length: int) =
  let expectedStr = "Expected " & $length & " Json parameter(s) but got "
  node.add(quote do:
    if `paramsIdent`.kind != JArray:
      raise newException(ValueError, "Parameter params expected JArray but got " & $`paramsIdent`.kind)
    if `paramsIdent`.len != `length`:
      raise newException(ValueError, `expectedStr` & $`paramsIdent`.len)
  )

proc setupParams(parameters, paramsIdent: NimNode): NimNode =
  # Add code to verify input and load parameters into Nim types
  result = newStmtList()
  if not parameters.isNil:
    # initial parameter array length check
    result.expectArrayLen(paramsIdent, parameters.len - 1)
    # unpack each parameter and provide assignments
    for i in 1 ..< parameters.len:
      let
        pos = i - 1
        paramName = parameters[i][0]
        paramNameStr = $paramName
        paramType = parameters[i][1]
      result.add(quote do:
        var `paramName` = `unpackArg`(`pos`, `paramNameStr`, `paramType`, `paramsIdent`)
      )

proc makeProcName(s: string): string =
  s.multiReplace((".", ""), ("/", ""))

macro on*(server: var RpcServer, path: string, body: untyped): untyped =
  result = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    paramsIdent = ident"params"  
    pathStr = $path
    procName = ident(pathStr.makeProcName)
  var
    setup = setupParams(parameters, paramsIdent)
    procBody: NimNode
    bodyWrapper = newStmtList()

  if body.kind == nnkStmtList: procBody = body
  else: procBody = body.body

  if parameters.len > 0 and parameters[0] != nil:
    # when a return type is specified, shadow async's result
    # and pass it back jsonified    
    let
      returnType = parameters[0]
      res = ident"result"
    template doMain(body: untyped): untyped =
      # create a new scope to allow shadowing result
      block:
        body
    bodyWrapper = quote do:
      `res` = `doMain`:
        var `res`: `returnType`
        `procBody`
        %`res`
  else:
    bodyWrapper = quote do: `procBody`
    
  # async proc wrapper around body
  result = quote do:
      proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
        `setup`
        `bodyWrapper`
      `server`.register(`path`, `procName`)
  when defined(nimDumpRpcs):
    echo "\n", pathStr, ": ", result.repr
