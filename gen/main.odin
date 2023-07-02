package vulkan_generator

import "core:os"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "core:strconv"
import "core:encoding/xml"
import "core:reflect"
import "core:runtime"

extensions: []string
platforms_table: [dynamic]Platform
extensions_table: [dynamic]Extension
types_table: [dynamic]Type
enums_table: [dynamic]Enum
commands_table: [dynamic]Command
formats_table: [dynamic]Format

Type_Category :: enum { Misc, Basetype, Bitmask, Define, Enum, Function_Pointer, Group, Handle, Include, Struct, Union, }
Limit_Type :: enum { No_Auto, Min, Max, Power_of_Two, Multiple, Bits_Precision, Bitmask, Range, Struct, Exact, }
Enum_Type :: enum { Constants, Enum, Bitmask, }
Extension_Type :: enum { Disabled, Instance, Device, }
Command_Kind :: enum { Global, Instance, Device, }
Numeric_Format :: enum { SFloat, SInt, SNorm, SRGB, SScaled, UFloat, UInt, UNorm, UScaled, }

Member_Index :: int
Type_Index :: int
Enum_Index :: int
Enum_Field_Index :: int
Command_Index :: int
Parameter_Index :: int
Extension_Index :: int
Format_Index :: int

Format_Component :: struct {
    name: string,
    bits: Maybe(int),
    numeric_format: Numeric_Format,
    plane_index: int,
}

Format_Plane :: struct {
    width_divisor: int,
    height_divisor: int,
    compatible: Format_Index,
}

Format :: struct {
    enum_field_index: Enum_Field_Index,
    class: string,
    block_size: int,
    texels_per_block: int,
    // defaults to {1, 1, 1}
    block_extent: [3]int,
    // optional field but "0" will never be a valid value so we can use that as the default
    packed: int,
    compressed: string,
    // denotes the YCbCr encoding if any
    chroma: string,
    components: []Format_Component,
    planes: []Format_Plane,
    spirv_formats: []string,
}

Extension_Enum :: struct {
    name: string,
    value: string,
    bitpos: string,
    extends: int,
    extnumber: string,
    offset: string,
    negative_value: bool,
    alias: int,
    protect: string,
}

Platform :: struct { name, protect, comment: string, }

Parameter :: struct {
    api: []string,
    len: []string,
    alt_len: []string,
    optional: []bool,
    selector: Member_Index,
    selection: string,
    no_auto_validity: bool,
    extern_sync: []string,
    object_type: Parameter_Index,
    valid_structs: []Type_Index,

    name: string,
    type: Type_Index,
}

Command :: struct {
    tasks: []string,
    queues: []string,
    success_codes: []string,
    error_codes: []string,
    renderpass_scope: string,
    video_encoding_scope: string,
    cmd_buffer_level: []string,
    comment: string,
    api: []string,
    alias: Maybe(Command_Index),
    description: string,

    name: string,
    return_type: Type_Index,
    parameters: []Parameter,
}

Enum_Field :: struct {
    name: string,
    alias: Maybe(Enum_Field_Index),
    comment: string,
    api: []string,
    value, 
    bitpos: string,
    type: Maybe(Type_Index),

}

Enum :: struct {
    name: string,
    type: Enum_Type,
    comment: string,
    vendor: string,
    
    start, end: int,
    bitwidth: int,

    fields: [dynamic]Enum_Field,
}

Member :: struct {
    type: Type_Index,
    name: string,

    api: []string,
    values: []string,
    len: []string,
    alt_len: []string,
    extern_sync: bool,
    optional: []bool,
    selector: Member_Index,
    selection: string,
    no_auto_validity: bool,
    limit_type: []Limit_Type,
    object_type: Member_Index,
    stride: Member_Index,
    comment: string,

    const_length: Maybe(int),
    const_length_literal: int,
}

Type :: struct {
    requires: Maybe(Type_Index),
    name: string,
    alias: Maybe(Type_Index),
    api: []string,
    category: Type_Category,
    comment: string,
    parent: Maybe(Type_Index), // used for handle types, the parent also being a handle type
    returned_only: bool,
    struct_extends: []Type_Index, // lists structs that can include this type in their pNext chain
    allow_duplicate: bool, // specifies whether multiple of this type can be used in the pNext chains of the structs in "struct_extends"
    object_type_enum: string, // if this type is an API object, then this is the associated enum for that kind of object

    nested_types: []Type_Index,
    api_entry: string, // unused?
    bit_values: Maybe(Type_Index),

    define_body: string,
    deprecated: bool,
    enum_definition: Maybe(Enum_Index),
    members: []Member,
}

Feature :: struct {
    api: string,
    name: string,
    number: string,
    sortorder: int,
    protect: string,
    comment: string,

    types: []Type_Index,
    commands: []Command_Index,
}

Extension_Constant :: struct { name, value, bitpos: string, }

Extension :: struct {
    name: string,
    number: string,
    author: string,
    contact: string,
    type: Extension_Type,
    requires: []string,
    requires_core: string,
    platform: string,
    supported: []string,
    promoted_to: string,
    deprecated_by: string,
    obsoleted_by: string,
    provisional: bool,
    special_use: []string,
    comment: string,

    constants: []Extension_Constant,
    enums: []Extension_Enum,
    commands: []Command_Index,
    types: []Type_Index,
}

get_element :: proc(doc: ^xml.Document, id: xml.Element_ID) -> map[string]string {
    res: map[string]string

    for attrib in doc.elements[id].attribs {
        res[attrib.key] = attrib.val
    }

    return res
}

// https://registry.khronos.org/vulkan/specs/1.3/styleguide.html#_assigning_extension_token_values
calculate_enum_offset :: proc(extension_number, offset: int) -> int {
    BASE_VALUE :: 1000000000
    RANGE_SIZE :: 1000

    return BASE_VALUE + (extension_number - 1) * RANGE_SIZE + offset
}

filter_commands :: proc(excluded_extensions: []Extension_Index, included_platforms: []string, allocator := context.temp_allocator) -> []Command_Index {
    filtered_commands := make([dynamic]Command_Index, allocator)

    outer: for c, i in commands_table {
        for ext, exti in extensions_table {
            if slice.contains(excluded_extensions, exti) || ext.platform != "" && !slice.contains(included_platforms, ext.platform) {
                for ci in ext.commands {
                    if ci == i {
                        continue outer
                    }
                }
            }
        }

        append(&filtered_commands, i)
    }

    return filtered_commands[:]
}

filter_types :: proc(excluded_extensions: []Extension_Index, included_platforms: []string, allocator := context.temp_allocator) -> []Type_Index {
    filtered_types := make([dynamic]Type_Index, allocator)

    outer: for c, i in types_table {
        for ext, exti in extensions_table {
            if slice.contains(excluded_extensions, exti) || ext.platform != "" && !slice.contains(included_platforms, ext.platform) {
                for ci in ext.types {
                    if ci == i {
                        continue outer
                    }
                }
            }
        }

        append(&filtered_types, i)
    }

    return filtered_types[:]
}

type_is_descendent_of :: proc(child: Type_Index, parent: Type_Index) -> bool {    
    child := child

    for types_table[child].alias != nil {
        child = types_table[child].alias.?
    }

    if types_table[child].parent == nil {
        return false
    }

    p := types_table[child].parent
    for p != nil {
        if p == parent {
            return true
        }

        p = types_table[p.?].alias if types_table[p.?].alias != nil else types_table[p.?].parent
    }

    return false
}

format_enum_field_name2 :: proc(e: Enum, field: Enum_Field) -> string {
    return format_enum_field_name(e.name, field.name)
}

omit_vulkan_prefix :: proc(s: string) -> string {
    if strings.has_prefix(s, "vk") || strings.has_prefix(s, "Vk") {
        return s[2:]
    } else if strings.has_prefix(s, "VK_") {
        return s[3:]
    }

    return s
}

get_parameter_element_name :: proc(doc: ^xml.Document, id: xml.Element_ID) -> (string, bool) {
    if name, found := xml.find_child_by_ident(doc, id, "name"); found {
        return doc.elements[name].value, true
    }

    return "", false
}

find_parameter_element_index_of_name :: proc(doc: ^xml.Document, params: []xml.Element_ID, name: string) -> (Member_Index, bool) {
    for param, i in params do if name_val, has_name := get_parameter_element_name(doc, param); has_name && name_val == name {
        return i, true
    }

    return -1, false
}

map_types_to_odin :: proc(type_name, decoration: string, forgive_void: bool = false) -> (ret_type_name: string, ret_decoration: string) {

    indirections := strings.count(decoration, "^")
    if indirections > 0 {
        decor_suffix :="^" if strings.has_suffix(decoration, "^") else "[^]"

        switch type_name {
            case "void": {
                ret_type_name = "rawptr"
                ret_decoration = strings.trim_suffix(decoration, decor_suffix)
            } return
            case "char": {
                ret_type_name = "cstring"
                ret_decoration = strings.trim_suffix(decoration, decor_suffix)
            } return
            case: {
                ret_decoration = decoration
            }
        }
    } else {
        switch type_name {
            case "void": {
                assert(forgive_void, "void on its own has no Odin analogue")
                ret_type_name = "rawptr"
            } return
            case "char": {
                ret_type_name = "byte"
            } return
        }
    }

    switch type_name {
        case "float": ret_type_name = "f32"
        case "double": ret_type_name = "f64"
        case "int8_t": ret_type_name = "i8"
        case "uint8_t": ret_type_name = "u8"
        case "int16_t": ret_type_name = "i16"
        case "uint16_t": ret_type_name = "u16"
        case "int32_t": ret_type_name = "i32"
        case "uint32_t": ret_type_name = "u32"
        case "int64_t": ret_type_name = "i64"
        case "uint64_t": ret_type_name = "u64"
        case "size_t": ret_type_name = "uint"
        case "int": ret_type_name = "c.int"
        case "VkBool32": ret_type_name = "b32"
        case: ret_type_name = type_name
    }

    return
}

calc_ptr_decore :: proc(index: Type_Index, var_name: string, array_len: []string, names: []string, allocator := context.temp_allocator) -> string {
    if var_name == "" {
        return ""
    }

    type_info := types_table[index]

    // vulkan breaks its variable/parameter/member annotation scheme with video encode/decode stuff specifically lmao
    if strings.has_prefix(var_name, "ppsID") {
        return ""
    }

    if unicode.is_upper(utf8.rune_at(var_name, 0)) {
        return ""
    }

    indirections := 0

    for char in var_name {
        if char != 'p' {
            if unicode.is_upper(char) {
                break
            }
            
            if type_info.name == "void" {
                return "^"
            }

            return ""
        }

        indirections += 1
    }

    assert(indirections > 0)
   
    is_array := array_len != nil

    ptr_decor := strings.repeat("^", indirections, context.temp_allocator)

    if is_array {
        ptr_decor = "[^]" if indirections == 1 else strings.concatenate({"[^]", ptr_decor[1:]}, context.temp_allocator)
    }

    return strings.clone(ptr_decor, allocator)
}

get_base_command :: proc(command: Command) -> Command {
    c := command

    for c.alias != nil {
        return commands_table[c.alias.?]
    }

    return command
}

command_has_return :: proc(c: Command) -> bool {
    return types_table[get_base_command(c).return_type].name != "void"
}

is_command_kind :: proc(command: Command) -> Command_Kind {
    c := command

    for c.alias != nil {
        c = commands_table[c.alias.?]
    }

    if c.parameters == nil {
        return .Global
    }

    if c.name == "vkGetInstanceProcAddr" {
        return .Global
    }

    if c.name == "vkGetDeviceProcAddr" {
        return .Instance
    }

    instance, instance_found := find_type_with_name("VkInstance")
    device, device_found := find_type_with_name("VkDevice")

    assert(instance_found)
    assert(device_found)

    if c.parameters[0].type == device || type_is_descendent_of(c.parameters[0].type, device) {
        return .Device
    }

    if c.parameters[0].type == instance || type_is_descendent_of(c.parameters[0].type, instance) {
        return .Instance
    }

    return .Global
}

generate_parameter_list :: proc(b: ^strings.Builder, command: Command, param_names: []string, allocator := context.temp_allocator) -> [][2]string {
    context.allocator = allocator

    res := make([][2]string, len(command.parameters), allocator)

    for param, i in command.parameters {
        decor := calc_ptr_decore(param.type, param.name, param.len, param_names)
        tname := types_table[param.type].name
        tname, decor = map_types_to_odin(tname, decor)

        if types_table[param.type].category == .Enum {
            if flags_name, flags_found := get_flags_of_bitflags(param.type); flags_found {
                tname = flags_name
            } else {
                tname = format_bitmask_enum_name(tname)
            }
        }
        
        res[i][0] = fmt.aprintf("{}", param.name)
        res[i][1] = fmt.aprintf("{}{}", decor, omit_vulkan_prefix(tname))
    }

    return res
}

generate_command_signature :: proc(command: Command, b: ^strings.Builder, mode: enum { func, type, pointer }) {
    c := get_base_command(command)
    
    name := c.name if c.alias == nil else commands_table[c.alias.?].name

    param_names := make([]string, len(c.parameters), context.temp_allocator)

    for param, i in c.parameters {
        param_names[i] = param.name
    }

    params := generate_parameter_list(b, c, param_names)

    switch mode {
        case .func: {
            strings.write_string(b, fmt.tprintf("{} :: proc(\n", omit_vulkan_prefix(command.name)))

            for param in params {
                strings.write_string(b, fmt.tprintf("\t{}: {},\n", param[0], param[1]))
            }

            if command_has_return(c) {
                tname, decor := map_types_to_odin(types_table[c.return_type].name, "")
                strings.write_string(b, fmt.tprintf("\t) -> {}", omit_vulkan_prefix(tname)))
            } else {
                strings.write_string(b, "\t)")
            }
        }
        case .type: {
            strings.write_string(b, fmt.tprintf("PFN_{} :: #type proc(", omit_vulkan_prefix(command.name)))

            for param, i in params {
                strings.write_string(b, fmt.tprintf("{}", param[1]))

                if i + 1 != len(c.parameters) {
                    strings.write_string(b, ", ")
                }
            }

            if command_has_return(c) {
                tname, decor := map_types_to_odin(types_table[c.return_type].name, "")
                strings.write_string(b, fmt.tprintf(") -> {}", omit_vulkan_prefix(tname)))
            } else {
                strings.write_string(b, ")")
            }
        }
        case .pointer: {
            strings.write_string(b, fmt.tprintf("@private ptr_{0}: PFN_{0}", omit_vulkan_prefix(command.name)))
        }
    }
}

process_parameter :: proc(doc: ^xml.Document, id: xml.Element_ID, params: []xml.Element_ID) -> (result: Parameter, good: bool) {
    attribs := get_element(doc, id)

    if "api" in attribs {
        result.api = process_api_tokens(attribs) or_return
    }

    if len_value, good := xml.find_attribute_val_by_key(doc, id, "len"); good {
        if strings.has_prefix(len_value, "latexmath:") {
            result.len = slice.clone([]string{len_value})

            // "altlen" only matters if "len" is declared and containing a latex equation
            if alt_len, good := xml.find_attribute_val_by_key(doc, id, "altlen"); good {
                result.alt_len = strings.split(alt_len, ",")
            }
        } else {
            result.len = strings.split(len_value, ",")
        }
    }

    if optional, good := xml.find_attribute_val_by_key(doc, id, "optional"); good {
        optional_list := strings.split(optional, ",", context.temp_allocator)
        result.optional = make([]bool, len(optional_list))
        for is_optional, i in optional_list {
            result.optional[i] = is_optional == "true"
        }
    }

    // points to member that specifies which union member to access
    if selector, good := xml.find_attribute_val_by_key(doc, id, "selector"); good {
        selector_index, good := find_parameter_element_index_of_name(doc, params, selector)
        assert(good)

        result.selector = selector_index
    }

    if selection, good := xml.find_attribute_val_by_key(doc, id, "selection"); good {
        result.selection = selection
    }

    // may or may not be of use, leaving in for now for completeness
    if no_auto_validity, good := xml.find_attribute_val_by_key(doc, id, "noautovalidity"); good {
        assert(no_auto_validity == "true")
        result.no_auto_validity = true
    }

    if extern_sync, good := xml.find_attribute_val_by_key(doc, id, "externsync"); good {
        result.extern_sync = strings.split(extern_sync, ",")
    }

    if object_type, good := xml.find_attribute_val_by_key(doc, id, "objecttype"); good {
        object_type_index, good := find_parameter_element_index_of_name(doc, params, object_type)
        assert(good)

        result.object_type = object_type_index
    }
    
    if valid_structs, good := xml.find_attribute_val_by_key(doc, id, "validstructs"); good {
        valid_structs_list := strings.split(valid_structs, ",", context.temp_allocator)
        valid_structs_indices := make([]Type_Index, len(valid_structs_list))

        for valid_struct_str, i in valid_structs_list {
            index, _ := find_type_with_name(valid_struct_str)
            valid_structs_indices[i] = index
        }

        result.valid_structs = valid_structs_indices
    }

    if name_tag, found := xml.find_child_by_ident(doc, id, "name"); found {
        result.name = doc.elements[name_tag].value
    }

    if type_tag, found := xml.find_child_by_ident(doc, id, "type"); found {
        type_index, good := find_type_with_name(doc.elements[type_tag].value)
        assert(good)

        result.type = type_index
    }
   
    return result, true
}

process_api_tokens :: proc(attribs: map[string]string, allocator := context.allocator) -> ([]string, bool) {
    api_tokens := strings.split(attribs["api"], ",", allocator)
    
    if slice.contains(api_tokens, "vulkansc") {
        delete(api_tokens, allocator)
        return nil, false
    }

    return api_tokens, true
}

process_command :: proc(doc: ^xml.Document, id: xml.Element_ID) -> (result: Command, good: bool) {

    attribs := get_element(doc, id)

    if "api" in attribs {
        result.api = process_api_tokens(attribs) or_return
    }

    if "tasks" in attribs {
        result.tasks = strings.split(attribs["tasks"], ",")
    }

    if "queues" in attribs {
        result.queues = strings.split(attribs["queues"], ",")
    }

    if "successcodes" in attribs {
        result.success_codes = strings.split(attribs["successcodes"], ",")
    }

    if "errorcodes" in attribs {
        result.error_codes = strings.split(attribs["errorcodes"], ",")
    }

    if "renderpass" in attribs {
        result.renderpass_scope = attribs["renderpass"]
    }

    if "videoencoding" in attribs {
        result.video_encoding_scope = attribs["videoencoding"]
    }

    if "cmdbufferlevel" in attribs {
        result.cmd_buffer_level = strings.split(attribs["cmdbufferlevel"], ",")
    }

    if "comment" in attribs {
        result.comment = attribs["comment"]
    }

    if "description" in attribs {
        result.description = attribs["description"]
    }

    if "name" in attribs {
        result.name = attribs["name"]

        // if their name is provided as an attribute, then there is no tag body, which means this is an alias

        if "alias" in attribs {
            index, found := find_command_table_with_name(doc, attribs["alias"])
            assert(found)
            result.alias = index
        }
    } else if proto_tag, found := xml.find_child_by_ident(doc, id, "proto"); found {
        name_tag, found1 := xml.find_child_by_ident(doc, proto_tag, "name")
        assert(found1)
        result.name = doc.elements[name_tag].value

        type_tag, found2 := xml.find_child_by_ident(doc, proto_tag, "type")
        assert(found2)

        for t, i in types_table do if t.name == doc.elements[type_tag].value {
            result.return_type = i
        }
    }

    params := make([dynamic]Parameter, 0, len(doc.elements[id].children), context.temp_allocator)
    for param_id in doc.elements[id].children do if doc.elements[param_id].ident == "param" {
        if param, good := process_parameter(doc, param_id, doc.elements[id].children[:]); good {
            append(&params, param)
        }
    }

    if len(params) > 0 {
        result.parameters = slice.clone(params[:])
    }

    return result, true
}

generate_procs :: proc() {
    b := strings.builder_make()

    strings.write_string(&b, "package vulkan_gen\n\n")
    strings.write_string(&b, "import \"core:c\"\n")
    strings.write_string(&b, "import \"core:dynlib\"\n")
    strings.write_string(&b, "\n")

    video_decode_h264 := get_extension_from_name("VK_KHR_video_decode_h264")
    video_decode_h265 := get_extension_from_name("VK_KHR_video_decode_h265")

    video_encode_h264 := get_extension_from_name("VK_EXT_video_encode_h264")
    video_encode_h265 := get_extension_from_name("VK_EXT_video_encode_h265")

    bad_extensions: []int = {
        video_decode_h264,
        video_decode_h265,
        video_encode_h264,
        video_encode_h265,
    }

    commands := filter_commands(bad_extensions, { "win32", })

    for index in commands {
        c := commands_table[index]

        generate_command_signature(c, &b, .type)
        strings.write_string(&b, "\n")
    }

    strings.write_string(&b, "\n")

    for index in commands {
        c := commands_table[index]
    
        generate_command_signature(c, &b, .pointer)
        strings.write_string(&b, "\n")
    }

    strings.write_string(&b, "\n")

    for index in commands {
        c := commands_table[index]
    
        generate_command_signature(c, &b, .func)
        strings.write_string(&b, " {\n\t")

        if command_has_return(c) {
            strings.write_string(&b, "return ")
        }

        strings.write_string(&b, fmt.tprintf("ptr_{}(", omit_vulkan_prefix(c.name)))

        for p, i in get_base_command(c).parameters {
            strings.write_string(&b, p.name)

            if i + 1 != len(get_base_command(c).parameters) {
                strings.write_string(&b, ", ")
            }
        }

        strings.write_string(&b, ")")


        strings.write_string(&b, "\n")

        strings.write_string(&b, "}\n")
        strings.write_string(&b, "\n")
    }

    strings.write_string(&b, "load_global_commands :: proc(library: dynlib.Library) {\n")

    for index in commands {
        c := commands_table[index]
        if is_command_kind(c) == .Global {
            strings.write_string(&b, fmt.tprintf("\tptr_{} = auto_cast dynlib.symbol_address(library, \"{}\")\n", omit_vulkan_prefix(c.name), c.name))
        }
    }

    strings.write_string(&b, "}\n")

    strings.write_string(&b, "load_instance_commands :: proc(instance: Instance) {\n")

    for index in commands {
        c := commands_table[index]
        if is_command_kind(c) == .Instance {
            strings.write_string(&b, fmt.tprintf("\tptr_{} = auto_cast GetInstanceProcAddr(instance, \"{}\")\n", omit_vulkan_prefix(c.name), c.name))
        }
    }

    strings.write_string(&b, "}\n")

    strings.write_string(&b, "load_device_commands :: proc(device: Device) {\n")

    for index in commands {
        c := commands_table[index]
        if is_command_kind(c) == .Device {
            strings.write_string(&b, fmt.tprintf("\tptr_{} = auto_cast GetDeviceProcAddr(device, \"{}\")\n", omit_vulkan_prefix(c.name), c.name))
        }
    }

    strings.write_string(&b, "}\n")

    os.write_entire_file("../procedures.odin", b.buf[:])
}

get_member_element_name :: proc(doc: ^xml.Document, member_id: xml.Element_ID) -> (string, bool) {
    if member_name, found := xml.find_child_by_ident(doc, member_id, "name"); found {
        return doc.elements[member_name].value, true
    }

    return "", false
}

find_member_element_index_of_name :: proc(doc: ^xml.Document, members: []xml.Element_ID, name: string) -> (Member_Index, bool) {
    for member, i in members do if name_val, has_name := get_member_element_name(doc, member); has_name && name_val == name {
        return i, true
    }

    return -1, false
}

process_member :: proc(doc: ^xml.Document, member_id: xml.Element_ID, parent_members: []xml.Element_ID) -> (member: Member, good: bool) {

    attribs := get_element(doc, member_id)

    if "api" in attribs {
        member.api = process_api_tokens(attribs) or_return
    }

    if name_tag, found := xml.find_child_by_ident(doc, member_id, "name"); found {
        member.name = doc.elements[name_tag].value
    }

    if comment_tag, found := xml.find_child_by_ident(doc, member_id, "comment"); found {
        member.comment = doc.elements[comment_tag].value
    }

    if type_tag, found := xml.find_child_by_ident(doc, member_id, "type"); found {
        type_index, good := search_type_in_xml(doc, doc.elements[type_tag].value)
        assert(good)

        member.type = type_index
    }

    if values, good := xml.find_attribute_val_by_key(doc, member_id, "values"); good {
        member.values = strings.split(values, ",")
    }

    if len_value, good := xml.find_attribute_val_by_key(doc, member_id, "len"); good {
        if strings.has_prefix(len_value, "latexmath:") {
            member.len = slice.clone([]string{len_value})

            // "altlen" only matters if "len" is declared and containing a latex equation
            if alt_len, good := xml.find_attribute_val_by_key(doc, member_id, "altlen"); good {
                member.alt_len = strings.split(alt_len, ",")
            }
        } else {
            member.len = strings.split(len_value, ",")
        }
    }

    if extern_sync, good := xml.find_attribute_val_by_key(doc, member_id, "externsync"); good {
        assert(extern_sync == "true")
        member.extern_sync = true
    }

    if optional, good := xml.find_attribute_val_by_key(doc, member_id, "optional"); good {
        optional_list := strings.split(optional, ",", context.temp_allocator)
        member.optional = make([]bool, len(optional_list))
        for is_optional, i in optional_list {
            member.optional[i] = is_optional == "true"
        }
    }

    // points to member that specifies which union member to access
    if selector, good := xml.find_attribute_val_by_key(doc, member_id, "selector"); good {
        selector_index, good := find_member_element_index_of_name(doc, parent_members, selector)
        assert(good)

        member.selector = selector_index
    }

    if selection, good := xml.find_attribute_val_by_key(doc, member_id, "selection"); good {
        member.selection = selection
    }

    // may or may not be of use, leaving in for now for completeness
    if no_auto_validity, good := xml.find_attribute_val_by_key(doc, member_id, "noautovalidity"); good {
        assert(no_auto_validity == "true")
        member.no_auto_validity = true
    }

    if limit_type, good := xml.find_attribute_val_by_key(doc, member_id, "limittype"); good {
        map_categories: map[string]Limit_Type = {
            "min" = .Min, 
            "max" = .Max, 
            "pot" = .Power_of_Two, 
            "mul" = .Multiple, 
            "bits" = .Bits_Precision, 
            "bitmask" = .Bitmask, 
            "range" = .Range, 
            "struct" = .Struct, 
            "exact" = .Exact, 
            "noauto" = .No_Auto,
        }

        limit_type_list := strings.split(limit_type, ",")

        member.limit_type = make([]Limit_Type, len(limit_type_list))

        for limit_type_item, i in limit_type_list {
            assert(limit_type_item in map_categories, fmt.tprint(limit_type_item))
            member.limit_type[i] = map_categories[limit_type_item]
        }
    }

    // specifically for members of type u64 for storing handles of API objects, "objecttype" type points to the member that denotes the type of API object
    if object_type, good := xml.find_attribute_val_by_key(doc, member_id, "objecttype"); good {
        object_type_index, good := find_member_element_index_of_name(doc, parent_members, object_type)
        assert(good)

        member.object_type = object_type_index
    }

    // byte stride between elements in an array, arrays are tightly packed by default and do not need this attribute
    if stride, good := xml.find_attribute_val_by_key(doc, member_id, "stride"); good {
        stride_index, good := find_member_element_index_of_name(doc, parent_members, stride)
        assert(good)

        member.stride = stride_index
    }

    if nested_enum, good := xml.find_child_by_ident(doc, member_id, "enum"); good {
        constant_name := doc.elements[nested_enum].value
        outer: for e in enums_table do if e.type == .Constants {
            for field, i in e.fields do if field.name == constant_name{
                member.const_length = i
                break outer
            }
        }
    } else if value := doc.elements[member_id].value; strings.has_prefix(value, "[") && strings.has_suffix(value, "]") {
        literal := strings.trim_prefix(strings.trim_suffix(value, "]"), "[")
        member.const_length_literal, _  = strconv.parse_int(literal)
        
    }

    return member, true
}

generate_defines :: proc(options: Options) {

    b := strings.builder_make()

    strings.write_string(&b, "package vulkan_gen\n\n")
    strings.write_string(&b, "import \"core:c\"\n\n")

    for t in types_table do if t.category == .Define {
        generate_type(options, t, &b, .Define)
    }

    strings.write_string(&b, "\n")    

    defines_windows := make([dynamic]Type_Index) 
    defer delete(defines_windows)

    for t, i in types_table do if requires, exists := t.requires.?; exists && t.category == .Misc {
        if types_table[requires].name == "windows.h" {
            append(&defines_windows, i)
        } 
    }

    strings.write_string(&b, fmt.tprintf("when ODIN_OS == .Windows {{\n"))
    strings.write_string(&b, fmt.tprintf("\timport \"core:sys/windows\"\n"))

    for i in defines_windows {
        strings.write_string(&b, fmt.tprintf("\t{0} :: windows.{0}\n", types_table[i].name))
    }

    strings.write_string(&b, fmt.tprintf("}}\n\n"))

    generate_constants(&b)

    os.write_entire_file("../defines.odin", b.buf[:])
}

generate_enums :: proc() {
    b := strings.builder_make()

    strings.write_string(&b, "package vulkan_gen\n\n")

    for t in types_table do if t.category == .Bitmask {
        underlying_type := "Flags64" if len(t.nested_types) > 0 && types_table[t.nested_types[0]].name == "VkFlags64" else "Flags"

        if alias, exists := t.alias.?; exists {
            strings.write_string(&b, fmt.tprintf("{} :: {}\n", format_bitmask_enum_name(t.name), format_bitmask_enum_name(types_table[alias].name)))
            continue
        }

        if requires, exists := t.requires.?; exists {
            bitmask_type := types_table[requires]
            strings.write_string(&b, fmt.tprintf("{} :: bit_set[{}; {}]\n", omit_vulkan_prefix(t.name), format_bitmask_enum_name(bitmask_type.name), underlying_type))
        
            for e in enums_table do if e.name == types_table[requires].name {
                generate_enum(e, &b)
                break
            }
        } else {
            strings.write_string(&b, fmt.tprintf("{} :: enum {} {{}}\n", format_bitmask_enum_name(t.name), underlying_type))
        }
        
        strings.write_string(&b, "\n")
    }

    outer: for t in types_table do if t.category == .Enum {
        if alias, exists := t.alias.?; exists {
            for e in enums_table do if e.type == .Bitmask && e.name == types_table[alias].name {
                continue outer
            }

            strings.write_string(&b, fmt.tprintf("{} :: {}\n", format_bitmask_enum_name(t.name), format_bitmask_enum_name(types_table[alias].name)))
            continue
        }

        for e in enums_table do if e.type == .Enum && e.name == t.name {
            generate_enum(e, &b)
            break
        }
    }

    os.write_entire_file("../enums.odin", b.buf[:])
}

generate_constants :: proc(b: ^strings.Builder) {
    for e in enums_table do if e.name == "API Constants" {
        for f in e.fields {
            switch f.name {
                case "VK_TRUE": {
                    strings.write_string(b, fmt.tprintf("{} :: true\n", omit_vulkan_prefix(f.name)))
                }
                case "VK_FALSE": {
                    strings.write_string(b, fmt.tprintf("{} :: false\n", omit_vulkan_prefix(f.name)))
                }
                case: {
                    if alias, exists := f.alias.?; exists {
                        strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(f.name), omit_vulkan_prefix(e.fields[alias].name)))
                    } else if strings.has_prefix(f.value, "(~") && strings.has_suffix(f.value, ")") {
                        value_str := strings.trim_suffix(strings.trim_prefix(f.value, "(~"), ")")

                        if strings.has_suffix(value_str, "ULL") {
                            value, value_good := strconv.parse_u64(strings.trim_suffix(value_str, "ULL"))
                            assert(value_good)
                            strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(f.name), fmt.tprintf("{}", ~value)))
                        }

                        if strings.has_suffix(value_str, "U") {
                            value, value_good := strconv.parse_u64(strings.trim_suffix(value_str, "U"))
                            assert(value_good)
                            strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(f.name), fmt.tprintf("{}", u32(~value))))
                        }
                    } else if strings.has_suffix(f.value, "F") {
                        strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(f.name), strings.trim_suffix(f.value, "F")))
                    } else {
                        strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(f.name), f.value))
                    }
                }
            }
        }
    }
}

get_extension_from_name :: proc(name: string) -> Extension_Index {
    for e, i in extensions_table do if e.name == name {
        return i
    }

    return -1
}

generate_types :: proc(options: Options) {
    b := strings.builder_make()

    strings.write_string(&b, "package vulkan_gen\n\n")
    strings.write_string(&b, "import \"core:c\"\n\n")

    video_decode_h264 := get_extension_from_name("VK_KHR_video_decode_h264")
    video_decode_h265 := get_extension_from_name("VK_KHR_video_decode_h265")

    video_encode_h264 := get_extension_from_name("VK_EXT_video_encode_h264")
    video_encode_h265 := get_extension_from_name("VK_EXT_video_encode_h265")

    bad_extensions: []int = {
        video_decode_h264,
        video_decode_h265,
        video_encode_h264,
        video_encode_h265,
    }

    filtered_types := filter_types(bad_extensions, {"win32"})

    for t in filtered_types do generate_type(options, types_table[t], &b, .Basetype)
    strings.write_string(&b, "\n")
    for t in filtered_types do generate_type(options, types_table[t], &b, .Handle)
    strings.write_string(&b, "\n")
    for t in filtered_types do generate_type(options, types_table[t], &b, .Function_Pointer)
    strings.write_string(&b, "\n")
    for t in filtered_types do generate_type(options, types_table[t], &b, .Struct)
    strings.write_string(&b, "\n")
    for t in filtered_types do generate_type(options, types_table[t], &b, .Union)
    strings.write_string(&b, "\n")

    os.write_entire_file("../structs.odin", b.buf[:])
}

make_version :: proc(major, minor, patch: u32) -> u32 {
    return (major << 22) | (minor << 12) | (patch)
}

make_api_version :: proc(variant, major, minor, patch: u32) -> u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | (patch)
}

get_flags_of_bitflags :: proc(type: Type_Index) -> (string, bool) {
    if types_table[type].category == .Enum {
        for e in enums_table do if e.type == .Bitmask && e.name == types_table[type].name {
            for t in types_table do if requires, exists := t.requires.?; exists && types_table[requires].name == e.name {
                return t.name, true
            } 
        }
    }

    return "", false
}

generate_member :: proc(options: Options, b: ^strings.Builder, member: Member, member_names: []string) {
    decor := calc_ptr_decore(member.type, member.name, member.len, member_names)
    tname := types_table[member.type].name
    tname, decor = map_types_to_odin(tname, decor)

    if types_table[member.type].category == .Enum {        
        tname = format_bitmask_enum_name(tname)
    }

    if !options.no_comment && member.comment != "" {
        strings.write_string(b, fmt.tprintf("\t// {}\n", member.comment))
    }

    if member.const_length == nil {
        if member.const_length_literal == 0 {

            if flags_name, flags_found := get_flags_of_bitflags(member.type); flags_found {
                strings.write_string(b, fmt.tprintf("\t{}: {}{},\n", member.name, decor, omit_vulkan_prefix(flags_name)))
            } else {
                strings.write_string(b, fmt.tprintf("\t{}: {}{},\n", member.name, decor, omit_vulkan_prefix(tname)))
            }
        } else {
            strings.write_string(b, fmt.tprintf("\t{}: [{}]{}{},\n", member.name, member.const_length_literal, decor, omit_vulkan_prefix(tname)))
        }
    } else {
        outer: for e in enums_table do if e.type == .Constants {
            for field, i in e.fields do if i == member.const_length {
                strings.write_string(b, fmt.tprintf("\t{}: [{}]{}{},\n", member.name, field.value, decor, omit_vulkan_prefix(tname)))
                break outer
            }
        }
    }
}

generate_type :: proc(options: Options, type: Type, b: ^strings.Builder, category: Type_Category) {
    if type.category != category {
        return
    }

    if slice.contains(type.api, "vulkansc") {
        return
    }

    #partial switch category {
        case .Basetype: {
            if len(type.nested_types) == 0 {
                return
            }

            tname, _ := map_types_to_odin(types_table[type.nested_types[0]].name, "", true)
            strings.write_string(b, fmt.tprintf("{} :: distinct {}\n", omit_vulkan_prefix(type.name), tname))
        }
        case .Misc: {
            // if type.requires != nil {
                // fmt.println(types_table[type.requires].name, type.name)
            // }
        }
        case .Bitmask: {
            // if type.requires != -1 do strings.write_string(b, fmt.tprintf("\trequires: {},\n", types_table[type.requires].name))
        }

        case .Define: {
            header_version, header_version_found := find_type_with_name("VK_HEADER_VERSION")
            assert(header_version_found)

            header_version_nospace, _ := strings.replace_all(types_table[header_version].define_body, " ", "", context.temp_allocator)
            parsed_header_version, parse_good := strconv.parse_uint(header_version_nospace, 10)
            assert(parse_good)

            defines := map[string]string {
                "VK_API_VERSION_1_0"        = fmt.tprint(make_api_version(0, 1, 0, 0)),
                "VK_API_VERSION_1_1"        = fmt.tprint(make_api_version(0, 1, 1, 0)),
                "VK_API_VERSION_1_2"        = fmt.tprint(make_api_version(0, 1, 2, 0)),
                "VK_API_VERSION_1_3"        = fmt.tprint(make_api_version(0, 1, 3, 0)),
                "VK_API_VERSION_COMPLETE"   = fmt.tprint(make_api_version(0, 1, 3, u32(parsed_header_version))),
                "VK_HEADER_VERSION"         = fmt.tprint(u32(parsed_header_version)),
                "VK_USE_64_BIT_PTR_DEFINES" = "true",
                "VK_NULL_HANDLE" = "rawptr(uintptr(0))",
            }

            if value, exists := defines[type.name]; exists {
                strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(type.name), value))
            }
        }

        case .Handle: {
            strings.write_string(b, fmt.tprintf("{} :: distinct {}\n", omit_vulkan_prefix(type.name), "rawptr"))
        }

        case .Function_Pointer: {
            strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(type.name), "rawptr"))
        }
        
        case .Struct: {
            if alias, exists := type.alias.?; exists {
                strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(type.name), omit_vulkan_prefix(types_table[alias].name)))

                return
            }

            if type.name == "VkTransformMatrixKHR" {
                strings.write_string(b, fmt.tprintf("{} :: struct {{\n", omit_vulkan_prefix(type.name)))
                strings.write_string(b, "\t_matrix: matrix[3, 4]f32,\n")
                strings.write_string(b, fmt.tprintf("}}\n"))

                return
            }

            if type.name == "VkScreenSurfaceCreateInfoQNX" {
                return
            }

            strings.write_string(b, fmt.tprintf("{} :: struct {{\n", omit_vulkan_prefix(type.name)))

            if type.members != nil {
                member_names := make([]string, len(type.members), context.temp_allocator)

                for member, i in type.members {
                    member_names[i] = member.name
                }
            
                for member in type.members {
                    generate_member(options, b, member, member_names)
                }
            }

            strings.write_string(b, "}\n")
        }

        case .Union: {
            strings.write_string(b, fmt.tprintf("{} :: struct #raw_union {{\n", omit_vulkan_prefix(type.name)))

            if type.members != nil {
                member_names := make([]string, len(type.members), context.temp_allocator)

                for member, i in type.members {
                    member_names[i] = member.name
                }
            
                for member in type.members {
                    generate_member(options, b, member, member_names)
                }
            }
            
            strings.write_string(b, "}\n")
        }
        
    }

}

handle_function_pointers :: proc(name: string) {
    switch name {
        case "PFN_vkInternalAllocationNotification": {
            
        }
        case "PFN_vkInternalFreeNotification": {
            
        }
        case "PFN_vkReallocationFunction": {
            
        }
        case "PFN_vkAllocationFunction": {
            
        }
        case "PFN_vkFreeFunction": {
            
        }
        case "PFN_vkVoidFunction": {
            
        }
        case "PFN_vkDebugReportCallbackEXT": {
            
        }
        case "PFN_vkDebugUtilsMessengerCallbackEXT": {
            
        }
        case "PFN_vkDeviceMemoryReportCallbackEXT": {
            
        }
        case "PFN_vkGetInstanceProcAddrLUNARG": {
            
        }
    }
}

process_type :: proc(doc: ^xml.Document, type_id: xml.Element_ID) -> (result: Type, good: bool) {

    attribs := get_element(doc, type_id)

    if "api" in attribs {
        result.api = process_api_tokens(attribs) or_return
    }

    map_categories: map[string]Type_Category = {
        "basetype" = .Basetype, 
        "bitmask" = .Bitmask, 
        "define" = .Define, 
        "enum" = .Enum, 
        "funcpointer" = .Function_Pointer, 
        "group" = .Group, 
        "handle" = .Handle, 
        "include" = .Include, 
        "struct" = .Struct,
        "union" = .Union,
    }

    if category, exists := attribs["category"]; exists {
        assert(category in map_categories)
        result.category = map_categories[category]
    }

    if requires, good := attribs["requires"]; good {
        required_struct_index, good := search_type_in_xml(doc, requires)
        assert(good)

        result.requires = required_struct_index
    } else if bitvalues, good := attribs["bitvalues"]; good {
        if bitvalues_index, exists := search_type_in_xml(doc, bitvalues); exists {
            result.requires = bitvalues_index
        }
    }

    if name, exists := attribs["name"]; exists {
        result.name = name
    } else if name_tag, found := xml.find_child_by_ident(doc, type_id, "name"); found {
        result.name = doc.elements[name_tag].value
    }

    if alias, exists := attribs["alias"]; exists {
        if alias_index, exists := search_type_in_xml(doc, alias); exists {
            result.alias = alias_index
        }
    }

    result.comment = attribs["comment"]
    result.returned_only = "returnedonly" in attribs

    if struct_extends, exists := attribs["structextends"]; exists {
        extended_structs := strings.split(struct_extends, ",")
        result.struct_extends = make([]Type_Index, len(extended_structs))

        for extended_struct, i in extended_structs {
            extended_struct_index, good := search_type_in_xml(doc, extended_struct)
            assert(good)

            result.struct_extends[i] = extended_struct_index
        }
    }

    result.allow_duplicate = attribs["allowduplicate"] == "true"

    if result.category == .Handle {
        if result.name == "" {
            if name_tag, found := xml.find_child_by_ident(doc, type_id, "name"); found {
                result.name = doc.elements[name_tag].value
            }
        }

        if parent, good := xml.find_attribute_val_by_key(doc, type_id, "parent"); good {
            parent_index, good := search_type_in_xml(doc, parent)
            assert(good)
    
            result.parent = parent_index
        }
    
        result.object_type_enum = attribs["objtypeenum"]
    }

    #partial switch result.category {
        case .Bitmask: {
            
        }
        case .Basetype: {
            
        }
        case .Function_Pointer: {
            
        }
        case .Define: {
            result.define_body = doc.elements[type_id].value
    
            // if strings.has_prefix(doc.elements[type_id].value, "// DEPRECATED: ") {
            //     result.deprecated = true
            // }
        }
        case .Struct: fallthrough
        case .Union: {
            members := make([dynamic]Member, 0, len(doc.elements[type_id].children))
            for child_id in doc.elements[type_id].children {
                if doc.elements[child_id].ident != "member" {
                    continue
                }

                if member, good := process_member(doc, child_id, doc.elements[type_id].children[:]); good {
                    append(&members, member)
                }
            }

            result.members = members[:]
        }
    }

    if doc.elements[type_id].children != nil {
        types := make([dynamic]Type_Index, 0, len(doc.elements[type_id].children), context.temp_allocator)
        for nested_type in doc.elements[type_id].children do if doc.elements[nested_type].ident == "type" {
            nested_type_index, found := search_type_in_xml(doc, doc.elements[nested_type].value)
            assert(found)

            append(&types, nested_type_index)
        }

        if len(types) > 0 {
            result.nested_types = slice.clone(types[:])
        }
    }

    return result, true
}

format_bitmask_enum_name :: proc(name: string) -> string {
    fixed_name, _ := strings.replace(omit_vulkan_prefix(name), "FlagBits", "Flag", 1, context.temp_allocator)
    return fixed_name
}

generate_enum :: proc(e: Enum, b: ^strings.Builder) {

    if e.type == .Bitmask {
        bitmask_enum_name := e.name
        
        underlying_type := "Flags64" if e.bitwidth == 64 else "Flags"

        strings.write_string(b, fmt.tprintf("{} :: enum {} {{\n", format_bitmask_enum_name(bitmask_enum_name), underlying_type))

        for field in e.fields {
            if field.value == "0" || (field.alias != nil && e.fields[field.alias.?].value == "0") {
                continue
            }

            if field.value != "" {
                continue
            }

            if alias, exists := field.alias.?; exists && e.fields[alias].value != "" {
                continue
            }

            if alias_index, exists := field.alias.?; exists {
                name := format_enum_field_name2(e, field)
                alias := format_enum_field_name2(e, e.fields[alias_index])
                
                if name == alias {
                    continue
                }

                strings.write_string(b, fmt.tprintf("\t\t{} = {},\n", name, alias))
            } else {
                strings.write_string(b, fmt.tprintf("\t\t{} = {},\n", format_enum_field_name2(e, field), field.bitpos if field.value == "" else field.value))                
            }
        }

        strings.write_string(b, "}\n")
    
    } else if e.type == .Enum {
        strings.write_string(b, fmt.tprintf("{} :: enum {} {{\n", omit_vulkan_prefix(e.name), "i32"))

        for field in e.fields {
            if alias, exists := field.alias.?; exists {
                strings.write_string(b, fmt.tprintf("\t{} = {},\n", format_enum_field_name2(e, field), format_enum_field_name2(e, e.fields[alias])))
            } else {
                strings.write_string(b, fmt.tprintf("\t{} = {},\n", format_enum_field_name2(e, field), field.value))
            }
        }

        strings.write_string(b, "}\n")
    } else if e.type == .Constants {
        for field in e.fields {
            if alias, exists := field.alias.?; exists {
                strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(field.name), omit_vulkan_prefix(e.fields[alias].name)))
            } else {
                val := field.value
                val, _ = strings.replace(val, "(~0U)", "max(u32)", 1)
                val, _ = strings.replace(val, "(~1U)", "~u32(1)", 1)
                val, _ = strings.replace(val, "(~2U)", "~u32(2)", 1)
                val, _ = strings.replace(val, "(~0ULL)", "max(u64)", 1)
                val, _ = strings.replace(val, "1000.0F", "1000.0", 1)
                
                strings.write_string(b, fmt.tprintf("{} :: {}\n", omit_vulkan_prefix(field.name), val))

            }
        }
        strings.write_string(b, "\n")
    }
}

find_enum_field_element_index_of_name :: proc(doc: ^xml.Document, fields: []xml.Element_ID, name: string) -> (Enum_Field_Index, bool) {
    counter := 0
    for field in fields do if doc.elements[field].ident == "enum" {
        if attrib_name, has_name := xml.find_attribute_val_by_key(doc, field, "name"); has_name && attrib_name == name {
            return counter, true
        }

        counter += 1
    }

    return -1, false
}

get_enum_field :: proc(doc: ^xml.Document, field_id: xml.Element_ID, fields: []xml.Element_ID) -> (field: Enum_Field, good: bool) {

    attribs := get_element(doc, field_id)

    field.api = process_api_tokens(attribs) or_return

    if name, exists := attribs["name"]; exists {
        field.name = name
    } else do panic("required attribute is missing")

    if "type" in attribs {
        type_index, good := search_type_in_xml(doc, attribs["type"])
        assert(good)

        field.type = type_index
    }

    if alias, good := attribs["alias"]; good {
        alias_index, good := find_enum_field_element_index_of_name(doc, fields, alias)
        assert(good)

        field.alias = alias_index
    }

    field.value = attribs["value"] or_else ""
    field.bitpos = attribs["bitpos"] or_else ""

    return field, true
}

process_enum :: proc(doc: ^xml.Document, enum_id: xml.Element_ID) -> (Enum, bool) {
    
    result: Enum

    name, good := xml.find_attribute_val_by_key(doc, enum_id, "name")
    assert(good, "required attribute is missing")

    if type, good := xml.find_attribute_val_by_key(doc, enum_id, "type"); good {
        map_enum_types: map[string]Enum_Type = {
            "enum" = .Enum, 
            "bitmask" = .Bitmask, 
        }

        assert(type in map_enum_types)

        result.type = map_enum_types[type]
    }
    
    result.name = name

    if start, good := xml.find_attribute_val_by_key(doc, enum_id, "start"); good {
        result.start, _ = strconv.parse_int(start)
    }

    if end, good := xml.find_attribute_val_by_key(doc, enum_id, "end"); good {
        result.end, _ = strconv.parse_int(end)
    }

    if bitwidth, good := xml.find_attribute_val_by_key(doc, enum_id, "bitwidth"); good {
        result.bitwidth, _ = strconv.parse_int(bitwidth)
    } else {
        result.bitwidth = 32
    }

    if comment, good := xml.find_attribute_val_by_key(doc, enum_id, "comment"); good {
        result.comment = comment
    }

    fields := make([dynamic]Enum_Field, 0, len(doc.elements[enum_id].children))

    for field in doc.elements[enum_id].children do if doc.elements[field].ident == "enum" {
        enum_field, good := get_enum_field(doc, field, doc.elements[enum_id].children[:])
        assert(good)
        append(&fields, enum_field)
    }

    result.fields = fields

    return result, true
}

process_extension :: proc(doc: ^xml.Document, id: xml.Element_ID) -> (Extension, bool) {
    result: Extension

    attribs := get_element(doc, id)

    result.name = attribs["name"]
    result.comment = attribs["comment"]
    result.author = attribs["author"]
    result.contact = attribs["contact"]
    result.requires_core = attribs["requiresCore"]
    result.platform = attribs["platform"]
    result.promoted_to = attribs["promotedto"]
    result.obsoleted_by = attribs["obsoletedby"]
    result.provisional = attribs["provisional"] == "true"
    result.number = attribs["number"]

    if val, good := attribs["supported"]; good {
        result.supported = strings.split(val, ",")
    }

    if val, good := attribs["specialuse"]; good {
        result.special_use = strings.split(val, ",")
    }

    if val, good := attribs["requires"]; good {
        result.requires = strings.split(val, ",")
    }

    if val, good := attribs["type"]; good {
        result.type = .Device if val == "device" else .Instance
    }

    if req, good := xml.find_child_by_ident(doc, id, "require"); good {
        ext_constants := make([dynamic]Extension_Constant, 0, len(doc.elements[req].children))
        ext_commands := make([dynamic]Command_Index, 0, len(doc.elements[req].children))
        ext_types := make([dynamic]Type_Index, 0, len(doc.elements[req].children))

        for child in doc.elements[req].children {
            switch doc.elements[child].ident {
                case "type": {
                    name, _ := xml.find_attribute_val_by_key(doc, child, "name")
                    index, _ := search_type_in_xml(doc, name)
                    append(&ext_types, index)
                }
                case "command": {
                    name, _ := xml.find_attribute_val_by_key(doc, child, "name")
                    index, _ := find_command_table_with_name(doc, name)
                    append(&ext_commands, index)
                }
                case "enum": {
                    extenum, good := process_extension_enum(doc, id, child)
                    
                    if !good {
                        continue
                    }

                    if extends, extends_good := xml.find_attribute_val_by_key(doc, child, "extends"); extends_good {
                        extended_enum, found := find_enum_with_name(extends)

                        append(&enums_table[extended_enum].fields, extenum)
                    } else {
                        for e in &enums_table do if e.name == "API Constants" {
                            append(&e.fields, extenum)
                        }
                    }
                }
            }
        }

        result.constants = ext_constants[:]
        result.commands = ext_commands[:]
        result.types = ext_types[:]
    }

    return result, true
}

get_extension_tags :: proc(doc: ^xml.Document, allocator := context.temp_allocator) -> []string {
    index, good := xml.find_child_by_ident(doc, 0, "tags")
    assert(good)

    names := make([]string, len(doc.elements[index].children), context.temp_allocator)

    for child, i in doc.elements[index].children {
        name, _ := xml.find_attribute_val_by_key(doc, child, "name")
        names[i] = name
    }

    return names
}

get_extension :: proc(name: string) -> (string, bool) {
    for ext in extensions do if strings.has_suffix(name, ext) {
        return ext, true
    }

    return "", false
}

format_enum_field_name :: proc(enum_name, field_name: string, allocator := context.temp_allocator) -> string {
    enum_name := enum_name
    enum_ext, enum_has_ext := get_extension(enum_name)

    if strings.contains(enum_name, "FlagBits") {
        segments := strings.split(enum_name, "FlagBits")
        if unicode.is_number(utf8.rune_at(segments[1], 0)) {
            enum_name, _ = strings.replace(enum_name, "FlagBits", "_", 1, context.temp_allocator)
        } else {
            enum_name, _ = strings.replace(enum_name, "FlagBits", "", 1, context.temp_allocator)
        }
    }

    enum_name, _ = strings.replace(enum_name, "H264", "H264_", 1, context.temp_allocator)
    enum_name, _ = strings.replace(enum_name, "H265", "H265_", 1, context.temp_allocator)
    screaming_enum_prefix := strings.to_screaming_snake_case(strings.trim_suffix(enum_name, enum_ext), context.temp_allocator)
    trimmed_enum_field := strings.trim_prefix(field_name, fmt.tprintf("{}_", screaming_enum_prefix))
    trimmed_enum_field, _ = strings.replace(trimmed_enum_field, "_BIT", "", 1)
    
    if unicode.is_number(utf8.rune_at(trimmed_enum_field, 0)) {
        if utf8.rune_at(trimmed_enum_field, 1) == 'D' {
            trimmed_enum_field = fmt.tprintf("{}{}", strings.reverse(trimmed_enum_field[:2]), trimmed_enum_field[2:])
        } else {
            trimmed_enum_field = fmt.tprintf("_{}", trimmed_enum_field)
        }
    }

    return strings.clone(omit_vulkan_prefix(trimmed_enum_field), allocator)
}

get_enum_bitwidth :: proc(doc: ^xml.Document, bitmask: xml.Element_ID) -> int {
    if bitwidth, has_bitwidth := xml.find_attribute_val_by_key(doc, bitmask, "bitwidth"); has_bitwidth {
        if value, is_valid := strconv.parse_int(bitwidth, 10); is_valid {
            return value
        }
    }
    
    return 32
}

search_type_in_xml :: proc(doc: ^xml.Document, name: string) -> (int, bool) {
    table_id, found := xml.find_child_by_ident(doc, 0, "types")
    assert(found)

    counter := 0

    for entry_index in doc.elements[table_id].children {
        entry := doc.elements[entry_index]
        
        if entry.ident == "type" {
            type_name, found := xml.find_attribute_val_by_key(doc, entry_index, "name")
            if found && type_name == name {
                return counter, true
            } else if name_tag, found := xml.find_child_by_ident(doc, entry_index, "name"); found && doc.elements[name_tag].value == name {
                return counter, true
            }

            counter += 1
        }
    }

    return -1, false
}

find_command_table_with_name :: proc(doc: ^xml.Document, name: string) -> (int, bool) {

    for command, i in commands_table do if command.name == name {
        return i, true
    }

    return -1, false
}

find_type_with_name :: proc(name: string) -> (int, bool) {

    for t, i in types_table do if t.name == name {
        return i, true
    }

    return -1, false
}

find_enum_with_name :: proc(name: string) -> (int, bool) {

    for t, i in enums_table do if t.name == name {
        return i, true
    }

    return -1, false
}

find_type_index_from_element_id :: proc(doc: ^xml.Document, element: xml.Element_ID) -> (int, bool) {
    table_id, found := xml.find_child_by_ident(doc, 0, "types")
    assert(found)

    counter := 0

    for entry_id in doc.elements[table_id].children {
        entry := doc.elements[entry_id]
        if entry.ident == "type" {
            if entry_id == element {
                return counter, true
            }

            counter += 1
        }
    }

    return -1, false
}

process_platform :: proc(doc: ^xml.Document, id: xml.Element_ID) -> (Platform, bool) {
    result: Platform

    if name, good := xml.find_attribute_val_by_key(doc, id, "name"); good {
        result.name = name
    }

    if protect, good := xml.find_attribute_val_by_key(doc, id, "protect"); good {
        result.protect = protect
    }

    if comment, good := xml.find_attribute_val_by_key(doc, id, "comment"); good {
        result.comment = comment
    }

    return result, true
}

process_extension_enum :: proc(doc: ^xml.Document, parent, child: xml.Element_ID) -> (Enum_Field, bool) {
    name, name_good := xml.find_attribute_val_by_key(doc, child, "name")

    for e in enums_table {
        for f in e.fields do if f.name == name {
            return {}, false
        }
    }

    if bitpos, bitpos_good := xml.find_attribute_val_by_key(doc, child, "bitpos"); bitpos_good {
        return {
            name = name,
            bitpos = bitpos,
        }, true
    }

    if offset, offset_good := xml.find_attribute_val_by_key(doc, child, "offset"); offset_good {
        _, dir_good := xml.find_attribute_val_by_key(doc, child, "dir")

        extnumber: string

        if doc.elements[parent].ident == "feature" {
            extnumber, _ = xml.find_attribute_val_by_key(doc, child, "extnumber")
        } else {
            extnumber, _ = xml.find_attribute_val_by_key(doc, parent, "number")
        }

        parsed_extnumber, parsed_extnumber_good := strconv.parse_int(extnumber)
        assert(parsed_extnumber_good)
        parsed_offset, _ := strconv.parse_int(offset)

        value := calculate_enum_offset(parsed_extnumber, parsed_offset)
        if dir_good {
            value = -value
        }

        return {
            name = name,
            value = fmt.aprintf("{}", value),
        }, true
    }

    if value, value_good := xml.find_attribute_val_by_key(doc, child, "value"); value_good {
        value, _ = strings.replace_all(value, "&quot;", "\"")
        return {
            name = name,
            value = value,
        }, true
    }

    alias, alias_good := xml.find_attribute_val_by_key(doc, child, "alias")
    if alias_good {

        for e, ei in enums_table do if e.type == .Enum {
            for f, fi in e.fields do if f.name == alias {

                return {
                    name = name,
                    alias = fi,
                    type = ei,
                }, true
            }
        }
    }



    return {}, false
}

process_feature :: proc(doc: ^xml.Document, id: xml.Element_ID) -> (Feature, bool) {
    result: Feature

    if name, good := xml.find_attribute_val_by_key(doc, id, "name"); good {
        result.name = name
    }

    if api, good := xml.find_attribute_val_by_key(doc, id, "api"); good {
        result.api = api
    }

    if number, good := xml.find_attribute_val_by_key(doc, id, "number"); good {
        result.number = number
    }

    if sortorder, good := xml.find_attribute_val_by_key(doc, id, "sortorder"); good {
        val, parsed :=  strconv.parse_int(sortorder, 10)
        result.sortorder = val if parsed else 0
    }

    if protect, good := xml.find_attribute_val_by_key(doc, id, "protect"); good {
        result.protect = protect
    }

    if comment, good := xml.find_attribute_val_by_key(doc, id, "comment"); good {
        result.comment = comment
    }

    for require_id in doc.elements[id].children do if doc.elements[require_id].ident == "require" {
        for child in doc.elements[require_id].children {
            switch doc.elements[child].ident {
                case "enum": {
                    extenum, good := process_extension_enum(doc, id, child)
                    
                    if !good {
                        continue
                    }

                    extends, extends_good := xml.find_attribute_val_by_key(doc, child, "extends")
                    assert(extends_good)

                    extended_enum, found := find_enum_with_name(extends)

                    append(&enums_table[extended_enum].fields, extenum)
                }
            }
        }
    }














    return result, true
}

process_basic_types :: proc(doc: ^xml.Document) {
    types_section, types_section_found := xml.find_child_by_ident(doc, 0, "types")
    for child in doc.elements[types_section].children do if doc.elements[child].ident == "type" {
        name, name_found := xml.find_attribute_val_by_key(doc, child, "name")
        category, category_found := xml.find_attribute_val_by_key(doc, child, "category")
        // requires, requires_found := xml.find_attribute_val_by_key(doc, child, "requires")
        parent, parent_found := xml.find_attribute_val_by_key(doc, child, "parent")
        objtypeenum, objtypeenum_found := xml.find_attribute_val_by_key(doc, child, "objtypeenum")
        alias, alias_found := xml.find_attribute_val_by_key(doc, child, "alias")

        if name_found && !category_found && !parent_found && !objtypeenum_found && !alias_found && doc.elements[child].children == nil {
            if processed_type, good := process_type(doc, child); good {
                append(&types_table, processed_type)
            }
        }
    }
}

xml_find_type_definition :: proc(doc: ^xml.Document, declaration: xml.Element_ID) -> (xml.Element_ID, bool) {
    types_section, types_section_found := xml.find_child_by_ident(doc, 0, "types")
    type_name, found := xml.find_attribute_val_by_key(doc, declaration, "name")
    assert(found)

    for child in doc.elements[types_section].children do if doc.elements[child].ident == "type" {
        if name, found := xml.find_attribute_val_by_key(doc, child, "name"); found && type_name == name {
            return child, true
        } else if name, found := xml.find_child_by_ident(doc, child, "name"); found && type_name == doc.elements[name].value {
            return child, true
        }
    }

    return 0, false
}

xml_find_command_definition :: proc(doc: ^xml.Document, declaration: xml.Element_ID) -> (xml.Element_ID, bool) {
    commands_section, commands_section_found := xml.find_child_by_ident(doc, 0, "commands")
    command_name, found := xml.find_attribute_val_by_key(doc, declaration, "name")
    assert(found)

    for child in doc.elements[commands_section].children do if doc.elements[child].ident == "command" {
        if name, found := xml.find_attribute_val_by_key(doc, child, "name"); found && command_name == name {
            return child, true
        } else if proto, found := xml.find_child_by_ident(doc, child, "proto"); found {
            if name, found := xml.find_child_by_ident(doc, proto, "name"); found && command_name == doc.elements[name].value {
                return child, true
            }
        }
    }

    return 0, false
}

generate_format_util_block_size :: proc(b: ^strings.Builder) {
    formats_enum_id: Enum_Index = -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    strings.write_string(b, "block_size :: proc(format: vulkan.Format) -> (int, bool) #optional_ok {\n")
    strings.write_string(b, "\t#partial switch format {\n")

    for f in formats_table {
        field := enums_table[formats_enum_id].fields[f.enum_field_index]

        for other_field in enums_table[formats_enum_id].fields do if other_field.alias == f.enum_field_index && other_field.value != "" {
            strings.write_string(b, fmt.tprintf("\t\tcase .{}: fallthrough\n", format_enum_field_name2(enums_table[formats_enum_id], other_field)))
        }

        strings.write_string(b, fmt.tprintf("\t\tcase .{}: return {}, true\n", format_enum_field_name2(enums_table[formats_enum_id], field), f.block_size))
    }

    strings.write_string(b, "\t}\n\n")

    strings.write_string(b, "\treturn 0, false\n")

    strings.write_string(b, "}\n")

}

generate_format_util_block_extent :: proc(b: ^strings.Builder) {
    formats_enum_id: Enum_Index = -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    strings.write_string(b, "block_extent :: proc(format: vulkan.Format) -> (vulkan.Extent3D, bool) #optional_ok {\n")
    strings.write_string(b, "\t#partial switch format {\n")

    for f in formats_table {
        field := enums_table[formats_enum_id].fields[f.enum_field_index]

        for other_field in enums_table[formats_enum_id].fields do if other_field.alias == f.enum_field_index && other_field.value != "" {
            strings.write_string(b, fmt.tprintf("\t\tcase .{}: fallthrough\n", format_enum_field_name2(enums_table[formats_enum_id], other_field)))
        }

        strings.write_string(b, fmt.tprintf("\t\tcase .{}: return {{{}, {}, {}}}, true\n", format_enum_field_name2(enums_table[formats_enum_id], field), f.block_extent.x, f.block_extent.y, f.block_extent.z))
    }

    strings.write_string(b, "\t}\n\n")

    strings.write_string(b, "\treturn {}, false\n")

    strings.write_string(b, "}\n")

}

generate_format_util_is_compressed :: proc(b: ^strings.Builder) {
    formats_enum_id: Enum_Index = -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    strings.write_string(b, "is_compressed :: proc(format: vulkan.Format) -> bool {\n")
    strings.write_string(b, "\t#partial switch format {\n")

    for f in formats_table {
        field := enums_table[formats_enum_id].fields[f.enum_field_index]

        for other_field in enums_table[formats_enum_id].fields do if other_field.alias == f.enum_field_index && other_field.value != "" {
            strings.write_string(b, fmt.tprintf("\t\tcase .{}: fallthrough\n", format_enum_field_name2(enums_table[formats_enum_id], other_field)))
        }

        strings.write_string(b, fmt.tprintf("\t\tcase .{}: return {}\n", format_enum_field_name2(enums_table[formats_enum_id], field), f.compressed != ""))
    }

    strings.write_string(b, "\t}\n\n")

    strings.write_string(b, "\treturn false\n")

    strings.write_string(b, "}\n")
}

generate_formats :: proc() {

    formats_enum_id: Enum_Index = -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    b := strings.builder_make()

    strings.write_string(&b, "package fmtutils\n\n")
    strings.write_string(&b, "import vulkan \"../\"\n")
    strings.write_string(&b, "\n")

    generate_format_util_block_size(&b)
    generate_format_util_block_extent(&b)
    generate_format_util_is_compressed(&b)

    if !os.exists("../fmtutils") do os.make_directory("../fmtutils")

    os.write_entire_file("../fmtutils/formats.odin", b.buf[:])
}

process_format :: proc(doc: ^xml.Document, id: xml.Element_ID) -> (Format, bool) {
    result: Format

    formats_enum_id: Enum_Index = -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    if name, good := xml.find_attribute_val_by_key(doc, id, "name"); good {
        for f, i in enums_table[formats_enum_id].fields do if f.name == name {
            result.enum_field_index = i
        }
    }

    if class, good := xml.find_attribute_val_by_key(doc, id, "class"); good {
        result.class = class
    }

    if block_size, good := xml.find_attribute_val_by_key(doc, id, "blockSize"); good {
        result.block_size, _ = strconv.parse_int(block_size, 10)
    }

    if texels_per_block, good := xml.find_attribute_val_by_key(doc, id, "texelsPerBlock"); good {
        result.texels_per_block, _ = strconv.parse_int(texels_per_block, 10)
    }

    if block_extent, good := xml.find_attribute_val_by_key(doc, id, "blockExtent"); good {
        extents := strings.split(block_extent, ",", context.temp_allocator)
        for extent, i in extents {
            result.block_extent[i], _ = strconv.parse_int(extent, 10)
        }
        
    } else {
        result.block_extent = {1, 1, 1}
    }

    if packed, good := xml.find_attribute_val_by_key(doc, id, "packed"); good {
        result.packed, _ = strconv.parse_int(packed, 10)
    }

    if compressed, good := xml.find_attribute_val_by_key(doc, id, "compressed"); good {
        result.compressed = compressed
    }

    if chroma, good := xml.find_attribute_val_by_key(doc, id, "chroma"); good {
        result.chroma = chroma
    }

    components := make([dynamic]Format_Component, 0, len(doc.elements[id].children), context.temp_allocator)
    planes := make([dynamic]Format_Plane, 0, len(doc.elements[id].children), context.temp_allocator)
    spirv_formats := make([dynamic]string, 0, len(doc.elements[id].children), context.temp_allocator)

    for child in doc.elements[id].children {
        switch doc.elements[child].ident {
            case "component": {
                comp: Format_Component

                /*
                    name: string,
                    bits: int,
                    numeric_format: Numeric_Format,
                    plane_index: int,
                */

                if name, good := xml.find_attribute_val_by_key(doc, child, "name"); good {
                    comp.name = name
                }

                if bits, good := xml.find_attribute_val_by_key(doc, child, "bits"); good {
                    if bits != "compressed" {
                        comp.bits, _ = strconv.parse_int(bits, 10)
                    }
                }

                if numeric_format, good := xml.find_attribute_val_by_key(doc, child, "numericFormat"); good {
                    switch numeric_format {
                        case "SFLOAT": comp.numeric_format = .SFloat
                        case "SINT": comp.numeric_format = .SInt
                        case "SNORM": comp.numeric_format = .SNorm
                        case "SRGB": comp.numeric_format = .SRGB
                        case "SSCALED": comp.numeric_format = .SScaled
                        case "UFLOAT": comp.numeric_format = .UFloat
                        case "UINT": comp.numeric_format = .UInt
                        case "UNORM": comp.numeric_format = .UNorm
                        case "USCALED": comp.numeric_format = .UScaled
                    }
                }

                if plane_index, good := xml.find_attribute_val_by_key(doc, child, "planeIndex"); good {
                    comp.plane_index, _ = strconv.parse_int(plane_index, 10)
                }
                
                append(&components, comp)
            }
            case "plane": {
                plane: Format_Plane

                index, good := xml.find_attribute_val_by_key(doc, child, "index")
                assert(good)
                
                parsed_index, _ := strconv.parse_int(index, 10)

                if parsed_index <= len(planes) {
                    resize_dynamic_array(&planes, parsed_index + 1)
                }

                if width_divisor, good := xml.find_attribute_val_by_key(doc, child, "widthDivisor"); good {
                    plane.width_divisor, _ = strconv.parse_int(width_divisor, 10)
                } else do panic("missing widthDivisor")

                if height_divisor, good := xml.find_attribute_val_by_key(doc, child, "heightDivisor"); good {
                    plane.height_divisor, _ = strconv.parse_int(height_divisor, 10)
                } else do panic("missing heightDivisor")

                if compatible, good := xml.find_attribute_val_by_key(doc, child, "compatible"); good {
                    plane.compatible = -1
                    
                    for f, i in formats_table do if enums_table[formats_enum_id].fields[f.enum_field_index].name == compatible {
                        plane.compatible = i
                    }

                    assert(plane.compatible != -1)
                } else do panic("missing compatible")

                planes[parsed_index] = plane
            }
            case "spirvimageformat": {
                spvfmt: string
                if name, good := xml.find_attribute_val_by_key(doc, child, "name"); good {
                    append(&spirv_formats, name)
                }
            }
        }
    }

    if len(components) != 0 {
        result.components = slice.clone(components[:])
    }

    if len(planes) != 0 {
        result.planes = slice.clone(planes[:])
    }

    if len(spirv_formats) != 0 {
        result.spirv_formats = slice.clone(spirv_formats[:])
    }

    return result, true
}

Options :: struct {
    no_comment: bool,
}

main :: proc() {
    options: Options

    for arg in os.args do switch arg {
        case "--no-comments": {
            options.no_comment = true 
        }
    }

    doc, err := xml.load_from_file("./Vulkan-Docs/xml/vk.xml", {flags={.Ignore_Unsupported, .Unbox_CDATA, .Decode_SGML_Entities}})
    defer xml.destroy(doc)
    assert(err == .None)

    extensions = get_extension_tags(doc, context.allocator)

    table_id, found := xml.find_child_by_ident(doc, 0, "types")
    commands_table_id, _ := xml.find_child_by_ident(doc, 0, "commands")
    extensions_table_id, _ := xml.find_child_by_ident(doc, 0, "extensions")
    features_table_id, _ := xml.find_child_by_ident(doc, 0, "features")
    platforms_table_id, _ := xml.find_child_by_ident(doc, 0, "platforms")
    formats_table_id, _ := xml.find_child_by_ident(doc, 0, "formats")

    enum_count := 0
    for tag in doc.elements[table_id].children do if doc.elements[tag].ident == "enums" {
        enum_count += 1
    }

    types_table = make([dynamic]Type)
    enums_table = make([dynamic]Enum)
    commands_table = make([dynamic]Command)
    extensions_table = make([dynamic]Extension)
    platforms_table = make([dynamic]Platform)
    formats_table = make([dynamic]Format)

    section_types := doc.elements[0]
    for entry_id in section_types.children {
        entry := doc.elements[entry_id]
        if entry.ident == "enums" {
            enum_info, good := process_enum(doc, entry_id)
            assert(good)

            append(&enums_table, enum_info)
        }
    }

    for type_id in doc.elements[table_id].children {
        if doc.elements[type_id].ident == "type" {
            if type_info, good := process_type(doc, type_id); true {
                append(&types_table, type_info)
            }
        }
    }

    for command_id in doc.elements[commands_table_id].children {
        if doc.elements[command_id].ident == "command" {
            if command_info, good := process_command(doc, command_id); good {
                append(&commands_table, command_info)
            }
        }
    }

    for id in doc.elements[platforms_table_id].children {
        if doc.elements[id].ident == "platform" {
            info, good := process_platform(doc, id)
            assert(good)

            append(&platforms_table, info)
        }
    }

    for id in doc.elements[features_table_id].children {
        if doc.elements[id].ident == "feature" {
            info, good := process_feature(doc, id)
            assert(good)
        }
    }

    for id in doc.elements[extensions_table_id].children {
        if doc.elements[id].ident == "extension" {
            info, good := process_extension(doc, id)
            assert(good)

            append(&extensions_table, info)
        }
    }

    for id in doc.elements[formats_table_id].children {
        if doc.elements[id].ident == "format" {
            info, good := process_format(doc, id)
            assert(good)

            append(&formats_table, info)
        }
    }

    generate_defines(options)
    generate_enums()
    generate_types(options)
    generate_procs()
    generate_formats()

    fmt.println("DONE")

}