local files  = require 'files'
local guide  = require 'parser.guide'
local vm     = require 'vm'
local infer  = require 'core.infer'
local await  = require 'await'
local define = require 'proto.define'
local hasVarargs, errType

local tableMap = {
    ['table']  = true,
    ['array']  = true,
    ['ltable'] = true,
    ['[]']     = true,
}
local typeNameMap = {
    ['doc.extends.name'] = true,
    ['doc.class.name']   = true,
    ['doc.alias.name']   = true,
    ['doc.type.name']    = true,
    ['doc.type.enum']    = true,
    ['doc.resume']       = true,

}

local function isTable(name)
    if tableMap[name]
    ---table<K: number, V: string> table
    or tableMap[name:sub(1, 5)]
    ---string[]
    or tableMap[name:sub(-2, -1)] then
        return true
    end
    return false
end

local function isClassOralias(typeName)
    if not typeName then
        return false
    elseif typeNameMap[typeName]
    or define.BuiltinType[typeName] then
        return true
    else
        return false
    end

end
local function inTypes(param, args)
    if string.sub(param.type, 1, 9) == 'doc.type.'
    and not param[1] then
        param[1] = string.sub(param.type, 10)
    end

    for _, v in ipairs(args) do
        if v[1] == 'any' then
            return true
        elseif param[1] == v[1] then
            return true
        elseif (param[1] == 'number' or param[1] == 'integer')
        and (v[1] == 'integer' or v[1] == 'number') then
            return true
        elseif v[1] == 'string' then
            ---处理alias
            --@alias searchmode '"ref"'|'"def"'
            if param[1] and param[1]:sub(1,1) == '"' then
                return true
            end
        elseif isTable(v[1] or v.type) and isTable(param[1] or param.type) then
            return true
        end
    end
    return false
end

local function addFatherClass(infers)
    for k in pairs(infers) do
        local docDefs = vm.getDocDefines(k)
        for _, doc in ipairs(docDefs) do
            if doc.parent
            and doc.parent.type == 'doc.class'
            and doc.parent.extends then
                for _, tp in ipairs(doc.parent.extends) do
                    if tp.type == 'doc.extends.name' then
                        infers[tp[1]] = true
                    end
                end
            end
        end
    end
end

local function getParamTypes(arg)
    if not arg then
        return false
    end
    local types
    if arg.type == '...' then
        types = {
            [1] = {
                [1] = '...',
                type = 'varargs'
            }
        }
        return true, types
    end
    ---处理doc.type.function
    if arg.type == 'doc.type.arg' then
        if arg.name and arg.name[1] == '...' then
            types = {
                [1] = {
                    [1] = '...',
                    type = 'varargs'
                }
            }
            return true, types
        end
        types = arg.extends.types
        return true, types
    end
    ---处理function
    local argDefs = vm.getDefs(arg)
    if #argDefs == 0 then
        return false
    end
    ---method, 如果self没有定义为一个class或者type，则认为它为any
    if arg.tag == 'self' then
        local types = {}
        local hasTable = false
        for _, argDef in ipairs(argDefs) do
            if argDef.type == 'doc.class.name'
            or argDef.type == 'doc.type.name' then
                types[#types+1] = argDef
            end
        end
        if #types == 0 then
            return false
        end
        return true, types
    end
    types = {}
    for _, argDef in ipairs(argDefs) do
        if argDef.type == 'doc.param' and argDef.extends then
            types = argDef.extends.types
            if argDef.optional then
                types[#types+1] = {
                    [1] = 'nil',
                    type = 'nil'
                }
            end
        elseif argDef.type == 'doc.type.enum' then
            types[#types+1] = argDef
        ---变长参数
        elseif argDef.name and argDef.name[1] == '...' then
            types = {
                [1] = {
                    [1] = '...',
                    type = 'varargs'
                }
            }
            break
        end
    end
    if #types == 0 then
        return false
    else
        return true, types
    end
end
local function getInfoFromDefs(defs)
    local paramsTypes = {}
    local funcArgsType
    local mark = {}
    for _, def in ipairs(defs) do
        funcArgsType = {}
        if def.value then
            def = def.value
        end
        if mark[def] then
            goto CONTINUE
        end
        mark[def] = true

        if def.type == 'function'
        or def.type == 'doc.type.function' then
            if def.args then
                for _, arg in ipairs(def.args) do
                    local suc, types = getParamTypes(arg)
                    if suc then
                        local plusAlias = {}
                        for i, tp in ipairs(types) do
                            local aliasDefs =  vm.getDefs(tp)
                            for _, v in ipairs(aliasDefs) do
                                ---TODO(arthur)
                                -- if not v.type then
                                -- end
                                if v[1] ~= tp[1]
                                and isClassOralias(v.type) then
                                    plusAlias[#plusAlias+1] = v
                                end
                                if not v[1] or not v.type then
                                    log.warn('type-check: if not v[1] or not v.type')
                                end
                            end
                            plusAlias[#plusAlias+1] = types[i]
                        end
                        funcArgsType[#funcArgsType+1] = plusAlias
                    else
                        funcArgsType = {}
                    end
                end
            end
            if #funcArgsType > 0 then
                paramsTypes[#paramsTypes+1] = funcArgsType
            end
        end
        ::CONTINUE::
    end
    return paramsTypes
end

local function isGeneric(type)
    if type.typeGeneric then
        return true
    end
    return false
end
local function matchParams(paramsTypes, i, arg)
    local flag = ''
    local messages = {}
    ---paramsTypes 存的是多个定义的参数信息
    ---paramTypes  存的是单独一个定义的参数信息
    ---param       是某一个定义中的第i个参数的信息
    for _, paramTypes in ipairs(paramsTypes) do
        if not paramTypes[i] then
            goto CONTINUE
        end
        flag = ''
        for _, param in ipairs(paramTypes[i]) do
            ---如果形参的类型在实参里面
            if inTypes(param, arg)
            or param[1] == 'any' then
                flag = ''
                return true
            elseif param[1] == '...' then
                hasVarargs = true
                return true
            ---如果是泛型，不检查
            elseif isGeneric(param) then
                return true
            else
                ---TODO(arthur) 什么时候param[1]是nil？
                if param[1] and not errType[param[1]] then
                    errType[param[1]] = true
                    flag = flag ..' ' .. (param[1] or '')
                end
            end
        end
        if flag ~= '' then
            local argm = '[ '
            for _, v in ipairs(arg) do
                argm = argm .. v[1]..' '
            end
            argm = argm .. ']'
            local message = 'Argument of type in '..argm..' is not assignable to parameter of type in ['..flag..' ]'
            if not messages[message] then
                messages[message] = true
                messages[#messages+1] = message
            end
        end
        ::CONTINUE::
    end
    return false, messages
end

local function isUserDefineClass(name)
    local defs = vm.getDocDefines(name)
    for _, v in ipairs(defs) do
        if v.type == 'doc.class.name' then
            return true
        end
    end
    return false
end
local function getArgsInfo(callArgs)
    local callArgsType = {}
    for _, arg in ipairs(callArgs) do
        local defs = vm.getDefs(arg)
        local infers = infer.searchInfers(arg)
        if infers['_G'] or infer['_ENV'] then
            infers['_G'] = nil
            infers['_ENV'] = nil
            infers['table'] = true
        end
        local hasAny = infers['any']
        ---处理继承
        addFatherClass(infers)
        if not hasAny then
            infers['any'] = nil
            infers['unknown'] = nil
        end
        local types = {}
        if not infers['table'] then
            for k in pairs(infers) do
                if not define.BuiltinType[k]
                and isUserDefineClass(k) then
                    infers['table'] = true
                    break
                end
            end
        end
        for k in pairs(infers) do
            if k then
                types[#types+1] = {
                    [1] = k,
                    type = k
                }
            end
        end
        if #types < 1 then
            return false
        end
        types.start = arg.start
        types.finish = arg.finish
        callArgsType[#callArgsType+1] = types
    end
    return true, callArgsType
end
return function (uri, callback)
    local ast = files.getState(uri)
    if not ast then
        return
    end
    guide.eachSourceType(ast.ast, 'call', function (source)
        if not source.args then
            return
        end
        await.delay()
        local callArgs = source.args
        local suc, callArgsType = getArgsInfo(callArgs)
        if not suc then
            return
        end
        local func = source.node
        local defs = vm.getDefs(func)
        ---只检查有emmy注释定义的函数
        local paramsTypes = getInfoFromDefs(defs)
        ---遍历实参
        for i, arg in ipairs(callArgsType) do
            ---遍历形参
            hasVarargs = false
            errType = {}
            local match, messages = matchParams(paramsTypes, i, arg)
            if hasVarargs then
                return
            end
            ---都不匹配
            if not match then
                if #messages > 0 then
                    callback{
                        start   = arg.start,
                        finish  = arg.finish,
                        message = table.concat(messages, '\n')
                    }
                end
            end
        end
        ---所有参数都匹配了
    end)

end
