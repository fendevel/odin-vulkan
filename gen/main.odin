package vulkan_generator

import "core:os"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "core:strconv"
import "core:encoding/xml"

Type_Category :: enum { Misc, Define, Basetype, Include, Handle, Bitmask, Enum, Function_Pointer, Group, Struct, Union, }
Limit_Type :: enum { No_Auto, Not, Min, Max, Power_of_Two, Multiple, Bits_Precision, Bitmask, Range, Struct, Exact, }
Enum_Type :: enum { Constants, Enum, Bitmask, }
Extension_Type :: enum { Disabled, Instance, Device, }
Command_Kind :: enum { Global, Instance, Device, }
Numeric_Format :: enum { SFloat, SInt, SNorm, SRGB, SScaled, UFloat, UInt, UNorm, UScaled, }

Member_Index :: int
Enum_Field_Index :: int
Format_Index :: int

Format_Component :: struct {
    name: string,
    bits: int,
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
    block_extent: [3]int,
    packed: int,
    compressed: string,
    chroma: string,
    components: []Format_Component,
    planes: []Format_Plane,
    spirv_formats: []string,
}

Extension_Enum :: struct {
    name: string,
    value: string,
    bitpos: string,
    extends: ^Type2,
    extnumber: string,
    offset: string,
    negative_value: bool,
    alias: int,
    protect: string,
}

Platform :: struct { name, protect, comment: string, }

Parameter2 :: struct {
    api: []string,
    len: []string,
    alt_len: []string,
    optional: []bool,
    no_auto_validity: bool,
    extern_sync: []string,
    object_type: ^Parameter2,
    valid_structs: []^Type2,

    name: string,
    type: ^Type2,
}

Command2 :: struct {
    tasks: []string,
    queues: []string,
    success_codes: []string,
    error_codes: []string,
    renderpass_scope: string,
    video_encoding_scope: string,
    cmd_buffer_level: []string,
    comment: string,
    api: []string,
    alias: ^Command2,
    description: string,

    name: string,
    return_type: ^Type2,
    parameters: []Parameter2,
}

Enum_Field2 :: struct {
    id: xml.Element_ID,
    type: ^Type2,
    name: string,
    alias: ^Enum_Field2,
    comment: string,
    api: []string,
    value: Maybe(int), 
    bitpos: Maybe(int),
}

Enum2 :: struct {
    id: xml.Element_ID,
    type: Enum_Type,
    name: string,
    comment: string,
    vendor: string,
    
    start, end: int,
    bitwidth: int,

    fields: [dynamic]Enum_Field2,
}

Member2 :: struct {
    type: ^Type2,
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

    const_length: ^Enum_Field2,
    const_length_literal: int,
}

Type2 :: struct {
    id: xml.Element_ID,
    category: Type_Category,
    requires: ^Type2,
    subtype: ^Type2,
    alias: ^Type2,
    parent: ^Type2,
    bitvalues: ^Type2,
    api: []string,

    name: string,

    members: []Member2,
}

Feature2 :: struct {
    api: string,
    name: string,
    number: string,
    sortorder: int,
    protect: string,
    comment: string,

    types: []^Type2,
    commands: []^Command2,
}

Extension_Constant :: struct { name, value, bitpos: string, }

Extension2 :: struct {
    name: string,
    number: int,
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
    commands: []^Command2,
    types: []^Type2,
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
        return doc.elements[name].value[0].(string)
    }

    return "", false
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
        case: ret_type_name = type_name
    }

    return
}

command_has_return2 :: proc(c: Command2) -> bool {
    return c.return_type != nil && c.return_type.name != "void"
}


get_member_element_name :: proc(doc: ^xml.Document, member_id: xml.Element_ID) -> (string, bool) {
    if member_name, found := xml.find_child_by_ident(doc, member_id, "name"); found {
        return doc.elements[member_name].value[0].?, true
    }

    return "", false
}

find_member_element_index_of_name :: proc(doc: ^xml.Document, members: []xml.Element_ID, name: string) -> (Member_Index, bool) {
    for member, i in members do if name_val, has_name := get_member_element_name(doc, member); has_name && name_val == name {
        return i, true
    }

    return -1, false
}

xml_gather_strings :: proc(doc: ^xml.Document, parent: xml.Element_ID, allocator := context.temp_allocator) -> []string {
    res := make([dynamic]string, 0, len(doc.elements[parent].value), allocator)
    for value in doc.elements[parent].value do if str, good := value.(string); good {
        append(&res, str)
    }

    return res[:]
}

generate_defines :: proc(doc: ^xml.Document, types_table: []Type2, enums_table: []Enum2) {

    b := strings.builder_make()

    fmt.sbprint(&b, "package vulkan_gen\n\n")
    // fmt.sbprint(&b, "import \"core:c\"\n\n")

    for t in types_table do if t.category == .Define {
        generate_type2(doc, t, &b, .Define, types_table, enums_table)
    }

    fmt.sbprint(&b, "\n")    

    generate_constants(doc, &b, enums_table)

    os.write_entire_file("../defines.odin", b.buf[:])
}

generate_enum2 :: proc(extensions: []string, e: Enum2, b: ^strings.Builder) {
    if e.type == .Bitmask {
        bitmask_enum_name := e.name
        
        underlying_type := "Flags64" if e.bitwidth == 64 else "Flags"

        fmt.sbprintf(b, "{} :: enum {} {{\n", format_bitmask_enum_name(bitmask_enum_name), underlying_type)

        for field in e.fields do if field.alias == nil {
            if field.value == 0 || (field.alias != nil && field.alias.value == 0) {
                continue
            }

            if field.value != nil {
                continue
            }

            if field.alias != nil && field.alias.value != nil {
                continue
            }

            fmt.sbprintf(b, "\t\t{} = {},\n", format_enum_field_name(extensions, e.name, field.name), field.bitpos if field.value == nil else field.value)
        }

        for field in e.fields do if field.alias != nil {
            if field.value == 0 || (field.alias != nil && field.alias.value == 0) {
                continue
            }

            if field.value != nil {
                continue
            }

            if field.alias != nil && field.alias.value != nil {
                continue
            }

            name := format_enum_field_name(extensions, e.name, field.name)
            alias := format_enum_field_name(extensions, e.name, field.alias.name)
            
            if name == alias {
                continue
            }

            fmt.sbprintf(b, "\t\t{} = {},\n", name, alias)
        }

        fmt.sbprint(b, "}\n")
    
    } else if e.type == .Enum {
        fmt.sbprintf(b, "{} :: enum {} {{\n", omit_vulkan_prefix(e.name), "i32")

        for field in e.fields do if field.alias == nil {
            if field.value != nil{
                fmt.sbprintf(b, "\t{} = {},\n", format_enum_field_name(extensions, e.name, field.name), field.value)
            }
        }

        for field in e.fields do if field.alias != nil {
            fmt.sbprintf(b, "\t{} = {},\n", format_enum_field_name(extensions, e.name, field.name), format_enum_field_name(extensions, e.name, field.alias.name))
        }

        fmt.sbprint(b, "}\n")
    } else if e.type == .Constants {
        // for field in e.fields {
        //     if field.alias == nil {
        //         val := field.value
        //         val, _ = strings.replace(val, "(~0U)", "max(u32)", 1)
        //         val, _ = strings.replace(val, "(~1U)", "~u32(1)", 1)
        //         val, _ = strings.replace(val, "(~2U)", "~u32(2)", 1)
        //         val, _ = strings.replace(val, "(~0ULL)", "max(u64)", 1)
        //         val, _ = strings.replace(val, "1000.0F", "1000.0", 1)
                
        //         fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(field.name), val)
        //     } else {
        //         fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(field.name), omit_vulkan_prefix(e.fields[field.alias].name))
        //     }
        // }
        fmt.sbprintln(b)
    }
}


generate_enums2 :: proc(extensions: []string, types_table: []Type2, enums_table: []Enum2) {
    b := strings.builder_make()

    fmt.sbprint(&b, "package vulkan_gen\n\n")

    for t in types_table do if t.category == .Bitmask {
        if t.alias != nil {
            fmt.sbprintf(&b, "{} :: {}\n", format_bitmask_enum_name(t.name), format_bitmask_enum_name(t.alias.name))
            continue
        }

        derived: ^Type2 = t.requires if t.requires != nil else t.bitvalues

        if derived != nil {
            fmt.sbprintf(&b, "{} :: bit_set[{}; {}]\n", omit_vulkan_prefix(t.name), format_bitmask_enum_name(derived.name), omit_vulkan_prefix(t.subtype.name))

            for &e in enums_table do if e.name == derived.name {
                generate_enum2(extensions, e, &b)
                break
            }

            continue
        }

        dummy_name, _ := strings.replace(omit_vulkan_prefix(t.name), "Flags", "Flag", 1, context.temp_allocator)
        fmt.sbprintf(&b, "{} :: bit_set[{}; {}]\n", omit_vulkan_prefix(t.name), dummy_name, omit_vulkan_prefix(t.subtype.name))
        fmt.sbprintf(&b, "{} :: enum {} {{}}\n", dummy_name, omit_vulkan_prefix(t.subtype.name))
    }

    outer: for t in types_table do if t.category == .Enum {
        if t.alias != nil {
            for e in enums_table do if e.type == .Bitmask && e.name == t.alias.name {
                continue outer
            }

            fmt.sbprintf(&b, "{} :: {}\n", format_bitmask_enum_name(t.name), format_bitmask_enum_name(t.alias.name))
            continue
        }

        for e in enums_table do if e.type == .Enum && e.name == t.name {
            generate_enum2(extensions, e, &b)
            break
        }
    }

    os.write_entire_file("../enums.odin", b.buf[:])
}

generate_constants :: proc(doc: ^xml.Document, b: ^strings.Builder, enums_table: []Enum2) {
    for e in enums_table do if e.name == "API Constants" {
        for f in e.fields {
            switch f.name {
                case "VK_TRUE": {
                    // fmt.sbprintf(b, "{} :: true\n", omit_vulkan_prefix(f.name))
                }
                case "VK_FALSE": {
                    // fmt.sbprintf(b, "{} :: false\n", omit_vulkan_prefix(f.name))
                }
                case: {
                    value, _ := xml.find_attribute_val_by_key(doc, f.id, "value")
                    value, _ = strings.replace_all(value, "&quot;", "\"", context.temp_allocator)

                    if f.alias != nil {
                        fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(f.name), omit_vulkan_prefix(f.alias.name))
                    } else if strings.has_prefix(value, "(~") && strings.has_suffix(value, ")") {
                        value_str := strings.trim_suffix(strings.trim_prefix(value, "(~"), ")")

                        if strings.has_suffix(value_str, "ULL") {
                            value, value_good := strconv.parse_u64(strings.trim_suffix(value_str, "ULL"))
                            assert(value_good)
                            fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(f.name), fmt.tprintf("{}", ~value))
                        }

                        if strings.has_suffix(value_str, "U") {
                            value, value_good := strconv.parse_u64(strings.trim_suffix(value_str, "U"))
                            assert(value_good)
                            fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(f.name), fmt.tprintf("{}", u32(~value)))
                        }
                    } else if strings.has_suffix(value, "F") {
                        fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(f.name), strings.trim_suffix(value, "F"))
                    } else {
                        fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(f.name), value)
                    }
                }
            }
        }
    }
}

calc_ptr_decore2 :: proc(type: ^Type2, var_name: string, array_len: []string, names: []string, allocator := context.temp_allocator) -> string {
    if var_name == "" {
        return ""
    }

    type_info := type

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

get_flags_of_bitflags2 :: proc(type: ^Type2, enums_table: []Enum2, types_table: []Type2) -> (string, bool) {
    if type.category == .Enum {
        for e in enums_table do if e.type == .Bitmask && e.name == type.name {
            for t in types_table do if t.requires != nil && t.requires.name == e.name {
                return t.name, true
            } 
        }
    }

    return "", false
}

generate_member2 :: proc(b: ^strings.Builder, doc: ^xml.Document, member: Member2, member_names: []string, enums_table: []Enum2, types_table: []Type2) {
    decor := calc_ptr_decore2(member.type, member.name, member.len, member_names)
    tname := member.type.name
    tname, decor = map_types_to_odin(tname, decor)

    if member.type.category == .Enum {        
        tname = format_bitmask_enum_name(tname)
    }

    if member.comment != "" {
        fmt.sbprintf(b, "\t// {}\n", member.comment)
    }

    if member.const_length == nil {
        if member.const_length_literal == 0 {

            if flags_name, flags_found := get_flags_of_bitflags2(member.type, enums_table, types_table); flags_found {
                fmt.sbprintf(b, "\t{}: {}{},\n", member.name, decor, omit_vulkan_prefix(flags_name))
            } else {
                fmt.sbprintf(b, "\t{}: {}{},\n", member.name, decor, omit_vulkan_prefix(tname))
            }
        } else {
            fmt.sbprintf(b, "\t{}: [{}]{}{},\n", member.name, member.const_length_literal, decor, omit_vulkan_prefix(tname))
        }
    } else {        
        fmt.sbprintf(b, "\t{}: [{}]{}{},\n", member.name, omit_vulkan_prefix(member.const_length.name), decor, omit_vulkan_prefix(tname))
    }
}

generate_type2 :: proc(doc: ^xml.Document, type: Type2, b: ^strings.Builder, category: Type_Category, types_table: []Type2, enums_table: []Enum2) {
    if type.category != category {
        return
    }

    #partial switch category {
        case .Basetype: {
            if type.subtype == nil {
                return
            }

            if type.name == "VkBool32" {
                fmt.sbprint(b, "Bool32 :: b32\n")
            } else {
                tname, _ := map_types_to_odin(type.subtype.name, "", true)
                fmt.sbprintf(b, "{} :: distinct {}\n", omit_vulkan_prefix(type.name), tname)
            }
        }
        case .Misc: {

            requires, good := xml.find_attribute_val_by_key(doc, type.id, "requires")
            if !good {
                return
            }

            if requires == "vk_platform" {
                return
            }
            
            fmt.sbprintf(b, "// requires: {}\n", requires)
            switch requires {
                case "windows.h": {
                    fmt.sbprintf(b, "{0} :: windows.{0}\n", type.name)
                }
                case: {
                    fmt.sbprintf(b, "{0} :: struct {{}}\n", type.name)
                }
            }
        }
        case .Bitmask: {
            // if type.requires != nil do fmt.sbprintf(b, "\trequires: {},\n", types_table[type.requires].name)
        }

        case .Define: {
            header_version, header_version_found := find_type_by_name(types_table[:], "VK_HEADER_VERSION")
            assert(header_version_found)
            
            header_version_nospace := strings.trim_space(doc.elements[header_version.id].value[2].?)
            parsed_header_version, parse_good := strconv.parse_uint(header_version_nospace, 10)
            assert(parse_good, header_version_nospace)

            switch type.name {
                case "VK_API_VERSION_1_0": {
                    fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(type.name), make_api_version(0, 1, 0, 0))
                }
                case "VK_API_VERSION_1_1": {
                    fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(type.name), make_api_version(0, 1, 1, 0))
                }
                case "VK_API_VERSION_1_2": {
                    fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(type.name), make_api_version(0, 1, 2, 0))
                }
                case "VK_API_VERSION_1_3": {
                    fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(type.name), make_api_version(0, 1, 3, 0))
                }
                case "VK_HEADER_VERSION_COMPLETE": {
                    fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(type.name), make_api_version(0, 1, 3, u32(parsed_header_version)))
                }
                case "VK_HEADER_VERSION": {
                    fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(type.name), parsed_header_version)
                }
                case "VK_NULL_HANDLE": {
                }
                case "VK_USE_64_BIT_PTR_DEFINES": {
                    fmt.sbprintf(b, "{} :: true\n", omit_vulkan_prefix(type.name))
                }
                case "VK_MAKE_VERSION": {
                    fmt.sbprintf(b, "{} :: proc(major, minor, patch: int) -> u32 {{\n\treturn (u32(major) << 22) | (u32(minor) << 12) | (u32(patch))\n}}\n", omit_vulkan_prefix(type.name))
                }
                case: {
                    return
                }
            }
        }

        case .Handle: {
            fmt.sbprintf(b, "{} :: distinct {}\n", omit_vulkan_prefix(type.name), "rawptr")
        }

        case .Function_Pointer: {
            fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(type.name), "rawptr")
        }
        
        case .Struct: {
            if type.alias != nil {
                fmt.sbprintf(b, "{} :: {}\n", omit_vulkan_prefix(type.name), omit_vulkan_prefix(type.alias.name))

                return
            }

            if type.name == "VkTransformMatrixKHR" {
                fmt.sbprintf(b, "{} :: struct {{\n", omit_vulkan_prefix(type.name))
                fmt.sbprint(b, "\t_matrix: matrix[3, 4]f32,\n")
                fmt.sbprintf(b, "}}\n")

                return
            }

            if type.name == "VkScreenSurfaceCreateInfoQNX" {
                return
            }

            fmt.sbprintf(b, "{} :: struct {{\n", omit_vulkan_prefix(type.name))

            if type.members != nil {
                member_names := make([]string, len(type.members), context.temp_allocator)

                for member, i in type.members {
                    member_names[i] = member.name
                }
            
                for member in type.members {
                    generate_member2(b, doc, member, member_names, enums_table, types_table)
                }
            }

            fmt.sbprintf(b, "}}\n")
        }
        case .Union: {
            fmt.sbprintf(b, "{} :: struct #raw_union {{\n", omit_vulkan_prefix(type.name))

            if type.members != nil {
                member_names := make([]string, len(type.members), context.temp_allocator)

                for member, i in type.members {
                    member_names[i] = member.name
                }
            
                for member in type.members {
                    generate_member2(b, doc, member, member_names, enums_table, types_table)
                }
            }
            
            fmt.sbprintf(b, "}}\n")
        }
        
    }

}

generate_types2 :: proc(doc: ^xml.Document, types_table: []Type2, extensions_table: []Extension2, enums_table: []Enum2) {
    b := strings.builder_make()

    fmt.sbprint(&b, "package vulkan_gen\n\n")
    fmt.sbprint(&b, "import \"core:c\"\n\n")
    fmt.sbprint(&b, "import \"core:sys/windows\"\n\n")

    platforms := []string{ "", "provisional", "win32", }

    for category in Type_Category {
        if category == .Define {
            continue
        }

        type_loop: for &t in types_table do if t.category == category {
            for ext in extensions_table do if slice.contains(ext.types, &t) {
                if (!slice.contains(platforms, ext.platform) || slice.contains([]string{ "VK_KHR_video_decode_h264", "VK_KHR_video_decode_h265", "VK_EXT_video_encode_h264", "VK_EXT_video_encode_h265", }, ext.name)) {
                    continue type_loop
                }
            }

            generate_type2(doc, t, &b, category, types_table, enums_table)
        }
        fmt.sbprint(&b, "\n")
    }

    os.write_entire_file("../structs.odin", b.buf[:])
}

generate_parameter_list2 :: proc(b: ^strings.Builder, command: Command2, param_names: []string, enums_table: []Enum2, types_table: []Type2, allocator := context.temp_allocator) -> [][2]string {
    context.allocator = allocator

    res := make([][2]string, len(command.parameters), allocator)

    for param, i in command.parameters {
        decor := calc_ptr_decore2(param.type, param.name, param.len, param_names)
        tname := param.type.name
        tname, decor = map_types_to_odin(tname, decor)

        if param.type.category == .Enum {
            if flags_name, flags_found := get_flags_of_bitflags2(param.type, enums_table, types_table); flags_found {
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

Func_Mode :: enum { Type, Pointer, Func, }

generate_command_signature2 :: proc(command: Command2, b: ^strings.Builder, mode: Func_Mode, enums_table: []Enum2, types_table: []Type2) {
    c := command.alias^ if command.alias != nil else command
    
    // name := c.name

    param_names := make([]string, len(c.parameters), context.temp_allocator)

    for param, i in c.parameters {
        param_names[i] = param.name
    }

    params := generate_parameter_list2(b, c, param_names, enums_table, types_table)

    switch mode {
        case .Func: {
            fmt.sbprintf(b, "{} :: proc(\n", omit_vulkan_prefix(command.name))

            for param in params {
                fmt.sbprintf(b, "\t{}: {},\n", param[0], param[1])
            }

            if command_has_return2(c) {
                tname, _ := map_types_to_odin(c.return_type.name, "")
                fmt.sbprintf(b, "\t) -> {}", omit_vulkan_prefix(tname))
            } else {
                fmt.sbprint(b, "\t)")
            }
        }
        case .Type: {
            fmt.sbprintf(b, "PFN_{} :: #type proc(", omit_vulkan_prefix(command.name))

            for param, i in params {
                fmt.sbprintf(b, "{}", param[1])

                if i + 1 != len(c.parameters) {
                    fmt.sbprint(b, ", ")
                }
            }

            if command_has_return2(c) {
                tname, _ := map_types_to_odin(c.return_type.name, "")
                fmt.sbprintf(b, ") -> {}", omit_vulkan_prefix(tname))
            } else {
                fmt.sbprint(b, ")")
            }
        }
        case .Pointer: {
            fmt.sbprintf(b, "@private ptr_{0}: PFN_{0}", omit_vulkan_prefix(command.name))
        }
    }
}

type_is_descendent_of2 :: proc(child: ^Type2, parent: ^Type2) -> bool {    
    child := child

    for child.alias != nil {
        child = child.alias
    }

    if child.parent == nil {
        return false
    }

    p := child.parent
    for p != nil {
        if p == parent {
            return true
        }

        p = p.parent if p.alias == nil else p.alias
    }

    return false
}

is_command_kind2 :: proc(c: Command2, commands_table: []Command2, types_table: []Type2) -> Command_Kind {
    c := c if c.alias == nil else c.alias^

    if c.parameters == nil {
        return .Global
    }

    if c.name == "vkGetInstanceProcAddr" {
        return .Global
    }

    if c.name == "vkGetDeviceProcAddr" {
        return .Instance
    }

    instance, instance_found := find_type_by_name(types_table, "VkInstance")
    device, device_found := find_type_by_name(types_table, "VkDevice")

    assert(instance_found)
    assert(device_found)

    if c.parameters[0].type == device || type_is_descendent_of2(c.parameters[0].type, device) {
        return .Device
    }

    if c.parameters[0].type == instance || type_is_descendent_of2(c.parameters[0].type, instance) {
        return .Instance
    }

    return .Global
}

generate_procs2 :: proc(commands_table: []Command2, types_table: []Type2, extensions_table: []Extension2, enums_table: []Enum2) {
    b := strings.builder_make()

    fmt.sbprint(&b, "package vulkan_gen\n\n")
    fmt.sbprint(&b, "import \"core:c\"\n")
    fmt.sbprint(&b, "import \"core:dynlib\"\n")
    fmt.sbprint(&b, "\n")

    platforms := []string{ "", "provisional", "win32", }

    for mode in Func_Mode {
        cmd_loop: for &c in commands_table {

            for ext in extensions_table {
                if slice.contains(ext.commands, &c) && (!slice.contains(platforms, ext.platform) || slice.contains([]string{ "VK_KHR_video_decode_h264", "VK_KHR_video_decode_h265", "VK_EXT_video_encode_h264", "VK_EXT_video_encode_h265", }, ext.name)) {
                    continue cmd_loop
                }
            }

            generate_command_signature2(c, &b, mode, enums_table, types_table)
            if mode == .Func {
                c := c.alias^ if c.alias != nil else c
                fmt.sbprint(&b, " {\n\t")

                if c.return_type != nil && c.return_type.name != "void" {
                    fmt.sbprint(&b, "return ")
                }
        
                fmt.sbprintf(&b, "ptr_{}(", omit_vulkan_prefix(c.name))
        
                base := c if c.alias == nil else c.alias^
        
                for p, i in base.parameters {
                    fmt.sbprint(&b, p.name)
        
                    if i + 1 != len(base.parameters) {
                        fmt.sbprint(&b, ", ")
                    }
                }
        
                fmt.sbprint(&b, ")")
        
        
                fmt.sbprint(&b, "\n")
        
                fmt.sbprint(&b, "}\n")
            }

            fmt.sbprint(&b, "\n")
        }
    }

    fmt.sbprint(&b, "load_global_commands :: proc(library: dynlib.Library) {\n")

    cmd_loop1: for &c in commands_table {
        for ext in extensions_table do if slice.contains(ext.commands, &c) {
            if (!slice.contains(platforms, ext.platform) || slice.contains([]string{ "VK_KHR_video_decode_h264", "VK_KHR_video_decode_h265", "VK_EXT_video_encode_h264", "VK_EXT_video_encode_h265", }, ext.name)) {
                continue cmd_loop1
            }
        }

        if is_command_kind2(c, commands_table, types_table) == .Global {
            fmt.sbprintf(&b, "\tptr_{} = auto_cast dynlib.symbol_address(library, \"{}\")\n", omit_vulkan_prefix(c.name), c.name)
        }
    }

    fmt.sbprint(&b, "}\n")

    fmt.sbprint(&b, "load_instance_commands :: proc(instance: Instance) {\n")

    cmd_loop2: for &c in commands_table {
        for ext in extensions_table do if slice.contains(ext.commands, &c) {
            if (!slice.contains(platforms, ext.platform) || slice.contains([]string{ "VK_KHR_video_decode_h264", "VK_KHR_video_decode_h265", "VK_EXT_video_encode_h264", "VK_EXT_video_encode_h265", }, ext.name)) {
                continue cmd_loop2
            }
        }

        if is_command_kind2(c, commands_table, types_table) == .Instance {
            fmt.sbprintf(&b, "\tptr_{} = auto_cast GetInstanceProcAddr(instance, \"{}\")\n", omit_vulkan_prefix(c.name), c.name)
        }
    }

    fmt.sbprint(&b, "}\n")

    fmt.sbprint(&b, "load_device_commands :: proc(device: Device) {\n")

    cmd_loop3: for &c in commands_table {
        for ext in extensions_table do if slice.contains(ext.commands, &c) {
            if (!slice.contains(platforms, ext.platform) || slice.contains([]string{ "VK_KHR_video_decode_h264", "VK_KHR_video_decode_h265", "VK_EXT_video_encode_h264", "VK_EXT_video_encode_h265", }, ext.name)) {
                continue cmd_loop3
            }
        }
        if is_command_kind2(c, commands_table, types_table) == .Device {
            fmt.sbprintf(&b, "\tptr_{} = auto_cast GetDeviceProcAddr(device, \"{}\")\n", omit_vulkan_prefix(c.name), c.name)
        }
    }

    fmt.sbprint(&b, "}\n")

    os.write_entire_file("../procedures.odin", b.buf[:])
}

make_version :: proc(major, minor, patch: u32) -> u32 {
    return (major << 22) | (minor << 12) | (patch)
}

make_api_version :: proc(variant, major, minor, patch: u32) -> u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | (patch)
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

format_bitmask_enum_name :: proc(name: string) -> string {
    fixed_name, _ := strings.replace(omit_vulkan_prefix(name), "FlagBits", "Flag", 1, context.temp_allocator)
    return fixed_name
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

get_extension_tags :: proc(doc: ^xml.Document, allocator := context.temp_allocator) -> []string {
    index, good := xml.find_child_by_ident(doc, 0, "tags")
    assert(good)

    names := make([]string, len(doc.elements[index].value), context.temp_allocator)

    
    for value, i in doc.elements[index].value do if child, good := value.(xml.Element_ID); good {
        name, _ := xml.find_attribute_val_by_key(doc, child, "name")
        names[i] = name
    }

    return names
}

get_extension :: proc(extensions: []string, name: string) -> (string, bool) {
    for ext in extensions do if strings.has_suffix(name, ext) {
        return ext, true
    }

    return "", false
}

format_enum_field_name :: proc(extensions: []string, enum_name, field_name: string, allocator := context.temp_allocator) -> string {
    enum_name := enum_name
    enum_ext, enum_has_ext := get_extension(extensions, enum_name)

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
    
    if enum_has_ext {
        enum_name = strings.trim_suffix(enum_name, enum_ext)
    }

    screaming_enum_prefix := strings.to_screaming_snake_case(enum_name, context.temp_allocator)
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

    for entry_index in xml_gather_children_with_ident(doc, table_id, "type") {
        entry := doc.elements[entry_index]
        
        if entry.ident == "type" {
            type_name, found := xml.find_attribute_val_by_key(doc, entry_index, "name")
            if found && type_name == name {
                return counter, true
            } else if name_tag, found := xml.find_child_by_ident(doc, entry_index, "name"); found && name == doc.elements[name_tag].value[0].? {
                return counter, true
            }

            counter += 1
        }
    }

    return -1, false
}

find_type_index_from_element_id :: proc(doc: ^xml.Document, element: xml.Element_ID) -> (int, bool) {
    table_id, found := xml.find_child_by_ident(doc, 0, "types")
    assert(found)

    counter := 0

    for entry_id in xml_gather_children_with_ident(doc, table_id, "type") {
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

xml_gather_children_with_ident :: proc (doc: ^xml.Document, parent: xml.Element_ID, ident: string, allocator := context.temp_allocator) -> []xml.Element_ID {
    children := make([dynamic]xml.Element_ID, 0, len(doc.elements[parent].value), allocator)

    nth := 0
    for {
        defer nth += 1

        child := xml.find_child_by_ident(doc, parent, ident, nth) or_break

        append(&children, child)
    }

    return children[:]
}

generate_format_util_block_size :: proc(b: ^strings.Builder, extensions: []string, formats_table: []Format, enums_table: []Enum2) {
    formats_enum_id := -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    fmt.sbprint(b, "block_size :: proc(format: vulkan.Format) -> (int, bool) #optional_ok {\n")
    fmt.sbprint(b, "\t#partial switch format {\n")

    for &f in formats_table {
        field := &enums_table[formats_enum_id].fields[f.enum_field_index]

        for other_field in enums_table[formats_enum_id].fields do if other_field.alias == field && other_field.value != nil {
            fmt.sbprintf(b, "\t\tcase .{}: fallthrough\n", format_enum_field_name(extensions, enums_table[formats_enum_id].name, other_field.name))
        }

        fmt.sbprintf(b, "\t\tcase .{}: return {}, true\n", format_enum_field_name(extensions, enums_table[formats_enum_id].name, field.name), f.block_size)
    }

    fmt.sbprint(b, "\t}\n\n")

    fmt.sbprint(b, "\treturn 0, false\n")

    fmt.sbprint(b, "}\n")

}

generate_format_util_block_extent :: proc(b: ^strings.Builder, extensions: []string, formats_table: []Format, enums_table: []Enum2) {
    formats_enum_id := -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    fmt.sbprint(b, "block_extent :: proc(format: vulkan.Format) -> (vulkan.Extent3D, bool) #optional_ok {\n")
    fmt.sbprint(b, "\t#partial switch format {\n")

    for f in formats_table {
        field := &enums_table[formats_enum_id].fields[f.enum_field_index]

        for other_field in enums_table[formats_enum_id].fields do if other_field.alias == field && other_field.value != nil {
            fmt.sbprintf(b, "\t\tcase .{}: fallthrough\n", format_enum_field_name(extensions, enums_table[formats_enum_id].name, other_field.name))
        }

        fmt.sbprintf(b, "\t\tcase .{}: return {{{}, {}, {}}}, true\n", format_enum_field_name(extensions, enums_table[formats_enum_id].name, field.name), f.block_extent.x, f.block_extent.y, f.block_extent.z)
    }

    fmt.sbprint(b, "\t}\n\n")

    fmt.sbprint(b, "\treturn {}, false\n")

    fmt.sbprint(b, "}\n")

}

generate_format_util_is_compressed :: proc(b: ^strings.Builder, extensions: []string, formats_table: []Format, enums_table: []Enum2) {
    formats_enum_id := -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    fmt.sbprint(b, "is_compressed :: proc(format: vulkan.Format) -> bool {\n")
    fmt.sbprint(b, "\t#partial switch format {\n")

    for f in formats_table {
        field := &enums_table[formats_enum_id].fields[f.enum_field_index]

        for other_field in enums_table[formats_enum_id].fields do if other_field.alias == field && other_field.value != nil {
            fmt.sbprintf(b, "\t\tcase .{}: fallthrough\n", format_enum_field_name(extensions, enums_table[formats_enum_id].name, other_field.name))
        }

        fmt.sbprintf(b, "\t\tcase .{}: return {}\n", format_enum_field_name(extensions, enums_table[formats_enum_id].name, field.name), f.compressed != "")
    }

    fmt.sbprint(b, "\t}\n\n")

    fmt.sbprint(b, "\treturn false\n")

    fmt.sbprint(b, "}\n")
}

generate_formats :: proc(extensions: []string, formats_table: []Format, enums_table: []Enum2) {

    formats_enum_id := -1
    for e, i in enums_table do if e.type == .Enum && e.name == "VkFormat" {
        formats_enum_id = i
    }

    assert(formats_enum_id != -1)

    b := strings.builder_make()

    fmt.sbprint(&b, "package fmtutils\n\n")
    fmt.sbprint(&b, "import vulkan \"../\"\n")
    fmt.sbprint(&b, "\n")

    generate_format_util_block_size(&b, extensions, formats_table, enums_table)
    generate_format_util_block_extent(&b, extensions, formats_table, enums_table)
    generate_format_util_is_compressed(&b, extensions, formats_table, enums_table)

    if !os.exists("../fmtutils") do os.make_directory("../fmtutils")

    os.write_entire_file("../fmtutils/formats.odin", b.buf[:])
}

process_format :: proc(doc: ^xml.Document, id: xml.Element_ID, formats_table: []Format, enums_table: []Enum2) -> (Format, bool) {
    result: Format

    formats_enum_id := -1
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

    components := make([dynamic]Format_Component, 0, len(doc.elements[id].value), context.temp_allocator)
    planes := make([dynamic]Format_Plane, 0, len(doc.elements[id].value), context.temp_allocator)
    spirv_formats := make([dynamic]string, 0, len(doc.elements[id].value), context.temp_allocator)

    for value in doc.elements[id].value do if child, good := value.(xml.Element_ID); good {
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
                    if bits == "compressed" {
                        comp.bits = -1
                    } else {
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

map_enum_type: map[string]Enum_Type = {
    "enum" = .Enum,
    "constants" = .Constants, 
    "bitmask" = .Bitmask, 
}

find_type_by_name :: proc(types: []Type2, name: string) -> (^Type2, bool) {
    for &type in types do if type.name == name {
        return &type, true
    }

    return nil, false
}

find_enum_by_name :: proc(enums: []Enum2, name: string) -> (^Enum2, bool) {
    for &enumeration in enums do if enumeration.name == name {
        return &enumeration, true
    }

    return nil, false
}

find_command_by_name :: proc(commands: []Command2, name: string) -> (^Command2, bool) {
    for &cmd in commands do if cmd.name == name {
        return &cmd, true
    }

    return nil, false
}

process_member2 :: proc(doc: ^xml.Document, member_id: xml.Element_ID, parent_members: []xml.Element_ID, types_table: []Type2, enums_table: []Enum2) -> Member2 {
    member: Member2 = {
    }

    if name_tag, found := xml.find_child_by_ident(doc, member_id, "name"); found {
        member.name = doc.elements[name_tag].value[0].?
    }

    if comment_tag, found := xml.find_child_by_ident(doc, member_id, "comment"); found {
        member.comment = doc.elements[comment_tag].value[0].?
    }

    if type_tag, found := xml.find_child_by_ident(doc, member_id, "type"); found {
        type_name: string = doc.elements[type_tag].value[0].?
        member.type = find_type_by_name(types_table, type_name) or_else panic(type_name)
    }

    if api, good := xml.find_attribute_val_by_key(doc, member_id, "api"); good {
        member.api = strings.split(api, ",")
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
            "not" = .Not, 
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
        constant_name := doc.elements[nested_enum].value[0].(string)

        outer: for e in enums_table {
            for &field in e.fields do if field.name == constant_name{
                member.const_length = &field
                break outer
            }
        }
    } else {
        values := xml_gather_strings(doc, member_id)
        for str in values do if strings.has_prefix(str, "[") && strings.has_suffix(str, "]") {
            literal := str[1:len(str) - 1]
            member.const_length_literal, _  = strconv.parse_int(literal)
        }
    }

    return member
}

process_types :: proc(doc: ^xml.Document, types_table: ^[dynamic]Type2, enums_table: ^[dynamic]Enum2) {
    types_table_id, found := xml.find_child_by_ident(doc, 0, "types")
    assert(found)

    types := xml_gather_children_with_ident(doc, types_table_id, "type")
    for type in types {
        category, has_category := xml.find_attribute_val_by_key(doc, type, "category")

        name, has_name_attrib := xml.find_attribute_val_by_key(doc, type, "name")
        if !has_name_attrib {
            tag := xml.find_child_by_ident(doc, type, "name") or_else panic("???")
            name = doc.elements[tag].value[0].?
        }

        t := Type2 {
            id = type,
            name = name,
            category = map_categories[category] if has_category else .Misc,
        }


        if api, good := xml.find_attribute_val_by_key(doc, type, "api"); good {
            if strings.contains(api, "vulkansc") {
                continue
            }

            t.api = strings.split(api, ",")
        }

        append(types_table, t)
    }

    for &type in types_table {
        requires: string = xml.find_attribute_val_by_key(doc, type.id, "requires") or_continue
        for &target in types_table do if target.name == requires {
            type.requires = &target
            break
        }
    }

    for &type in types_table {
        if parent, good := xml.find_attribute_val_by_key(doc, type.id, "parent"); good {
            type.parent = find_type_by_name(types_table[:], parent) or_else panic("???")
        }
    }

    for &type in types_table {

        subtype, has_subtype := xml.find_child_by_ident(doc, type.id, "type")
        if has_subtype {
            subtype_name: string = doc.elements[subtype].value[0].?
            type.subtype = find_type_by_name(types_table[:], subtype_name) or_else fmt.panicf("{:#v}", doc.elements[type.id])
        }

        if alias, has_alias := xml.find_attribute_val_by_key(doc, type.id, "alias"); has_alias {
            type.alias = find_type_by_name(types_table[:], alias) or_else panic("???")
        }

        if bitvalues, has_bitvalues := xml.find_attribute_val_by_key(doc, type.id, "bitvalues"); has_bitvalues {
            type.bitvalues = find_type_by_name(types_table[:], bitvalues) or_else panic("???")
        }
    }

    for &type in types_table {
        xml_members := xml_gather_children_with_ident(doc, type.id, "member")
        members := make([dynamic]Member2, 0, len(xml_members), context.temp_allocator)
        
        for m in xml_members {
            if api, has_api := xml.find_attribute_val_by_key(doc, m, "api"); has_api {
                list := strings.split(api, ",", context.temp_allocator) if strings.contains(api, ",") else { api, }
                if len(list) > 0 && !slice.contains(list, "vulkan") {
                    continue
                }
            }

            append(&members, process_member2(doc, m, xml_members, types_table[:], enums_table[:]))
        }

        type.members = members[:]
    }
}

process_feature_enums :: proc(doc: ^xml.Document, enums_table: []Enum2) {
    features_table_id, _ := xml.find_child_by_ident(doc, 0, "features")
    features := xml_gather_children_with_ident(doc, features_table_id, "feature")

    for feature in features {
        if api, has_api := xml.find_attribute_val_by_key(doc, feature, "api"); has_api {
            list := strings.split(api, ",", context.temp_allocator) if strings.contains(api, ",") else { api, }
            if len(list) > 0 && !slice.contains(list, "vulkan") {
                continue
            }
        }

        requires := xml_gather_children_with_ident(doc, feature, "require")
        for r in requires {
            enums := xml_gather_children_with_ident(doc, r, "enum")
            for e in enums {
                if len(doc.elements[e].attribs) == 1 {
                    continue
                }

                process_extended_enum(doc, enums_table[:], e, nil)
            }
        }
    }
}

process_extended_enum :: proc(doc: ^xml.Document, enums_table: []Enum2, e: xml.Element_ID, extension_number: Maybe(string)) {
    name := xml.find_attribute_val_by_key(doc, e, "name") or_else panic("???")
    
    extends, has_extends := xml.find_attribute_val_by_key(doc, e, "extends")
    extendenum: ^Enum2
    
    if has_extends {
        for &e in enums_table do if e.name == extends {
            extendenum = &e
            break
        }
    } else {
        for &e in enums_table do if e.name == "API Constants" {
            extendenum = &e
            break
        }
    }

    for f in extendenum.fields do if f.name == name {
        return
    }
            

    fbitpos: Maybe(int)

    if bitpos, bitpos_good := xml.find_attribute_val_by_key(doc, e, "bitpos"); bitpos_good {
        fbitpos = strconv.parse_int(bitpos) or_else panic("???")
    }

    fval: Maybe(int)

    if offset, offset_good := xml.find_attribute_val_by_key(doc, e, "offset"); offset_good {
        _, dir_good := xml.find_attribute_val_by_key(doc, e, "dir")

        extnumber: string
        if val, has_extnumber := xml.find_attribute_val_by_key(doc, e, "extnumber"); has_extnumber {
            extnumber = val
        } else {
            assert(extension_number != nil)
            extnumber = extension_number.?
        }

        parsed_extnumber, parsed_extnumber_good := strconv.parse_int(extnumber)
        assert(parsed_extnumber_good)
        parsed_offset, _ := strconv.parse_int(offset)

        value := calculate_enum_offset(parsed_extnumber, parsed_offset)
        if dir_good {
            value = -value
        }

        fval = value
    }

    if value, value_good := xml.find_attribute_val_by_key(doc, e, "value"); value_good {
        value, _ = strings.replace_all(value, "&quot;", "\"")
        value_int, good := strconv.parse_int(value)
        fval = value_int if good else nil
    }

    append(&extendenum.fields, Enum_Field2{
        id = e,
        name = name,
        value = fval,
        bitpos = fbitpos,
    })
}

process_extended_enums :: proc(doc: ^xml.Document, enums_table: []Enum2) {
    extensions_table_id, _ := xml.find_child_by_ident(doc, 0, "extensions")
    extensions := xml_gather_children_with_ident(doc, extensions_table_id, "extension")

    for ext in extensions {
        ext_number, has_ext_number := xml.find_attribute_val_by_key(doc, ext, "number")
        requires := xml_gather_children_with_ident(doc, ext, "require")
        for r in requires {
            extenums := xml_gather_children_with_ident(doc, r, "enum")
            for e in extenums {
                if len(doc.elements[e].attribs) == 1 {
                    continue
                }

                process_extended_enum(doc, enums_table[:], e, ext_number if has_ext_number else nil)
            }
        }
    }
}

process_enums :: proc(doc: ^xml.Document, enums_table: ^[dynamic]Enum2, types_table: ^[dynamic]Type2) {
    enums := xml_gather_children_with_ident(doc, 0, "enums")
    for enumeration in enums {
        name := xml.find_attribute_val_by_key(doc, enumeration, "name") or_else panic("???")
        type := map_enum_type[xml.find_attribute_val_by_key(doc, enumeration, "type") or_else "constants"]
        fields := xml_gather_children_with_ident(doc, enumeration, "enum")

        if name == "API Constants" {
            type = .Constants
        }

        bitwidth := 0
        if bitwidth_str, has_bitwidth := xml.find_attribute_val_by_key(doc, enumeration, "bitwidth"); has_bitwidth {
            bitwidth = strconv.parse_int(bitwidth_str) or_else panic("???")
        }

        enum_fields := make([dynamic]Enum_Field2, 0, len(fields) + 0x100, context.temp_allocator)
        for field in fields {
            f := Enum_Field2 {
                id = field,
                name = xml.find_attribute_val_by_key(doc, field, "name") or_else panic("???"),
            }
            
            defer append(&enum_fields, f)

            if type != .Constants {
                if value, found := xml.find_attribute_val_by_key(doc, field, "value"); found {
                    f.value = strconv.parse_int(value) or_else fmt.panicf("{:#v}", doc.elements[field])
                }
    
                if bitpos, found := xml.find_attribute_val_by_key(doc, field, "bitpos"); found {
                    f.bitpos = strconv.parse_int(bitpos) or_else panic("???")
                }    
            }
        }

        append(enums_table, Enum2 {
            type = type,
            name = name,
            fields = enum_fields,
            bitwidth = bitwidth,
        })
    }

    process_feature_enums(doc, enums_table[:])
    process_extended_enums(doc, enums_table[:])

    for &e in enums_table {
        for &f in e.fields {
            if alias, found := xml.find_attribute_val_by_key(doc, f.id, "alias"); found {
                for &f2 in e.fields do if f2.name == alias {
                    f.alias = &f2
                    if f.name == "VK_FORMAT_FEATURE_TRANSFER_SRC_BIT_KHR" {
                        fmt.printfln("{:#v}", f)
                    }
                    break
                }
            }
        }
    }
}

process_parameter2 :: proc(doc: ^xml.Document, id: xml.Element_ID, params: []xml.Element_ID, params2: []Parameter2, types_table: []Type2) -> Parameter2 {
    result: Parameter2

    if api, good := xml.find_attribute_val_by_key(doc, id, "api"); good {
        result.api = strings.split(api, ",")
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

    // may or may not be of use, leaving in for now for completeness
    if no_auto_validity, good := xml.find_attribute_val_by_key(doc, id, "noautovalidity"); good {
        assert(no_auto_validity == "true")
        result.no_auto_validity = true
    }

    if extern_sync, good := xml.find_attribute_val_by_key(doc, id, "externsync"); good {
        result.extern_sync = strings.split(extern_sync, ",")
    }

    if object_type, good := xml.find_attribute_val_by_key(doc, id, "objecttype"); good {
        for &p in params2 do if p.name == object_type {
            result.object_type = &p
            break    
        }
    }
    
    if valid_structs, good := xml.find_attribute_val_by_key(doc, id, "validstructs"); good {
        valid_structs_list := strings.split(valid_structs, ",", context.temp_allocator)
        valid_structs_indices := make([]^Type2, len(valid_structs_list))

        for valid_struct_str, i in valid_structs_list {
            valid_structs_indices[i] = find_type_by_name(types_table, valid_struct_str) or_else panic("???")
        }

        result.valid_structs = valid_structs_indices
    }

    if name_tag, found := xml.find_child_by_ident(doc, id, "name"); found {
        result.name = doc.elements[name_tag].value[0].?
    }

    if type_tag, found := xml.find_child_by_ident(doc, id, "type"); found {
        type_name, type_name_good := doc.elements[type_tag].value[0].(string)
        assert(type_name_good)

        result.type = find_type_by_name(types_table, type_name) or_else panic("???")
    }
   
    return result
}

process_command2 :: proc(doc: ^xml.Document, id: xml.Element_ID, commands_table: []Command2, types_table: []Type2) -> Command2 {
    result: Command2

    attribs := get_element(doc, id)

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

    if "api" in attribs {
        result.api = strings.split(attribs["api"], ",")
    }

    if "description" in attribs {
        result.description = attribs["description"]
    }

    if "name" in attribs {
        result.name = attribs["name"]

        // if their name is provided as an attribute, then there is no tag body, which means this is an alias

        if "alias" in attribs {
            alias := find_command_by_name(commands_table[:], attribs["alias"]) or_else panic("???")
            result.alias = alias
        }
    } else if proto_tag, found := xml.find_child_by_ident(doc, id, "proto"); found {
        name_tag, found1 := xml.find_child_by_ident(doc, proto_tag, "name")
        assert(found1)
        result.name = doc.elements[name_tag].value[0].?

        type_tag, found2 := xml.find_child_by_ident(doc, proto_tag, "type")
        assert(found2)

        result.return_type, _ = find_type_by_name(types_table, doc.elements[type_tag].value[0].?)
    }

    params := make([dynamic]Parameter2, 0, len(doc.elements[id].value), context.temp_allocator)
    xml_params := xml_gather_children_with_ident(doc, id, "param")
    for param_id in xml_params {

        if api, has_api := xml.find_attribute_val_by_key(doc, param_id, "api"); has_api {
            list := strings.split(api, ",", context.temp_allocator) if strings.contains(api, ",") else { api, }
            if len(list) > 0 && !slice.contains(list, "vulkan") {
                continue
            }
        }

        append(&params, process_parameter2(doc, param_id, xml_params, params[:], types_table))
    }

    if len(params) > 0 {
        result.parameters = slice.clone(params[:])
    }

    return result
}
process_commands :: proc(doc: ^xml.Document, commands_table: ^[dynamic]Command2, types_table: ^[dynamic]Type2) {
    commands_table_id, _ := xml.find_child_by_ident(doc, 0, "commands")
    commands := xml_gather_children_with_ident(doc, commands_table_id, "command")
    resize_dynamic_array(commands_table, len(commands))
    clear(commands_table)

    for cmd in commands {
        if api, has_api := xml.find_attribute_val_by_key(doc, cmd, "api"); has_api {
            list := strings.split(api, ",", context.temp_allocator) if strings.contains(api, ",") else { api, }
            if len(list) > 0 && !slice.contains(list, "vulkan") {
                continue
            }
        }

        append(commands_table, process_command2(doc, cmd, commands_table[:], types_table[:]))
    }
}

process_extension_enum2 :: proc(doc: ^xml.Document, parent, child: xml.Element_ID, enums_table: []Enum2) -> Enum_Field2 {
    name, has_name := xml.find_attribute_val_by_key(doc, child, "name")
    assert(has_name)

    res := Enum_Field2 {
        id = child,
        name = name,
    }

    extends, has_extends := xml.find_attribute_val_by_key(doc, child, "extends")
    extendenum: ^Enum2
    
    if has_extends {
        for &e in enums_table do if e.name == extends {
            extendenum = &e
            break
        }
    } else {
        for &e in enums_table do if e.name == "API Constants" {
            extendenum = &e
            break
        }
    }

    if bitpos, bitpos_good := xml.find_attribute_val_by_key(doc, child, "bitpos"); bitpos_good {
        res.bitpos = strconv.parse_int(bitpos) or_else panic("???")
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

        res.value = value
    }

    if value, value_good := xml.find_attribute_val_by_key(doc, child, "value"); value_good {
        value, _ = strings.replace_all(value, "&quot;", "\"")
        value_int, good := strconv.parse_int(value)
        res.value = value_int if good else nil
    }

    if alias, alias_good := xml.find_attribute_val_by_key(doc, child, "alias"); alias_good {
        for &f in extendenum.fields do if f.name == alias {
            res.alias = &f
            break
        }
    }

    return res
}

process_extension2 :: proc(doc: ^xml.Document, id: xml.Element_ID, types_table: []Type2, enums_table: []Enum2, commands_table: []Command2) -> Extension2 {
    result: Extension2

    if name, good := xml.find_attribute_val_by_key(doc, id, "name"); good {
        result.name = name
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "comment"); good {
        result.comment = val
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "author"); good {
        result.author = val
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "contact"); good {
        result.contact = val
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "requiresCore"); good {
        result.requires_core = val
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "platform"); good {
        result.platform = val
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "promotedto"); good {
        result.promoted_to = val
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "obsoletedby"); good {
        result.obsoleted_by = val
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "provisional"); good {
        result.provisional = val == "true"
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "supported"); good {
        result.supported = strings.split(val, ",")
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "specialuse"); good {
        result.special_use = strings.split(val, ",")
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "number"); good {
        result.number = strconv.parse_int(val) or_else panic("???")
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "requires"); good {
        result.requires = strings.split(val, ",")
    }

    if val, good := xml.find_attribute_val_by_key(doc, id, "type"); good {
        result.type = .Device if val == "device" else .Instance
    }

    if req, good := xml.find_child_by_ident(doc, id, "require"); good {
        ext_constants := make([dynamic]Extension_Constant, 0, len(doc.elements[req].value))
        ext_commands := make([dynamic]^Command2, 0, len(doc.elements[req].value))
        ext_types := make([dynamic]^Type2, 0, len(doc.elements[req].value))

        outer2: for value in doc.elements[req].value do if child, good := value.(xml.Element_ID); good {
            switch doc.elements[child].ident {
                case "type": {
                    name, _ := xml.find_attribute_val_by_key(doc, child, "name")
                    type := find_type_by_name(types_table, name) or_else panic("???")
                    append(&ext_types, type)
                }
                case "command": {
                    name, _ := xml.find_attribute_val_by_key(doc, child, "name")
                    cmd, _ := find_command_by_name(commands_table, name)
                    append(&ext_commands, cmd)
                }
                case "enum": {
                    
                }
            }
        }

        result.constants = ext_constants[:]
        result.commands = ext_commands[:]
        result.types = ext_types[:]
    }

    return result
}

process_extensions :: proc(doc: ^xml.Document, extensions_table: ^[dynamic]Extension2, types_table: ^[dynamic]Type2, enums_table: ^[dynamic]Enum2, commands_table: ^[dynamic]Command2) {
    extensions_table_id, _ := xml.find_child_by_ident(doc, 0, "extensions")
    extensions := xml_gather_children_with_ident(doc, extensions_table_id, "extension")

    for ext in extensions {
        if supported, good := xml.find_attribute_val_by_key(doc, ext, "supported"); good {
            list := strings.split(supported, ",", context.temp_allocator)
            if len(list) > 0 && !slice.contains(list, "vulkan") {
                continue
            }
        }

        append(extensions_table, process_extension2(doc, ext, types_table[:], enums_table[:], commands_table[:]))
    }

    for ext in extensions_table {
        for enumeration in ext.enums {
            e, _ := find_enum_by_name(enums_table[:], enumeration.name)
            for &f in e.fields {
                if alias, has_alias := xml.find_attribute_val_by_key(doc, f.id, "alias"); has_alias {
                    for &f2 in e.fields do if f2.name == alias {
                        f.alias = &f2
                        break
                    }
                }
            }
        }
    }
}

process_feature2 :: proc(doc: ^xml.Document, id: xml.Element_ID, types_table: []Type2, enums_table: []Enum2, commands_table: []Command2) -> Feature2 {
    result: Feature2

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

    fmt.println("feature:", result.name)

    for required_items in xml_gather_children_with_ident(doc, id, "require") {
        for element, element_id in doc.elements do if element.parent == required_items {
            if element.ident == "comment" {
                continue
            }

            name, name_found := xml.find_attribute_val_by_key(doc, xml.Element_ID(element_id), "name")
            fmt.assertf(name_found, "assert at element: {}", element)
            fmt.printf("\tchecking {}: {}... ", element.ident, name)

            found: bool
            switch element.ident {
                case "command": _, found = find_command_by_name(commands_table, name)
                case "type": _, found = find_type_by_name(types_table, name)
                case "enum": {
                    if extends, does_extend := xml.find_attribute_val_by_key(doc, xml.Element_ID(element_id), "extends"); does_extend {
                        if enum_type, enum_found := find_enum_by_name(enums_table, extends); enum_found {
                            for field in enum_type.fields do if field.name == name {
                                found = true
                            }
                        }
                    } else {
                        if enum_type, enum_found := find_enum_by_name(enums_table, "API Constants"); enum_found {
                            for field in enum_type.fields do if field.name == name {
                                found = true
                            }
                        }
                    }
                }
            }

            fmt.assertf(found, "failed to find required {}: {} of feature: {}", element.ident, name, result.name)
            fmt.println("good!")
        }
    }

    return result
}

process_features :: proc(doc: ^xml.Document, features_table: ^[dynamic]Feature2, extensions_table: ^[dynamic]Extension2, types_table: ^[dynamic]Type2, enums_table: ^[dynamic]Enum2, commands_table: ^[dynamic]Command2) {
    features_table_id, _ := xml.find_child_by_ident(doc, 0, "features")
    features := xml_gather_children_with_ident(doc, features_table_id, "feature")
    resize(features_table, len(features))
    clear(features_table)

    for feature in features {
        if api, has_api := xml.find_attribute_val_by_key(doc, feature, "api"); has_api {
            list := strings.split(api, ",", context.temp_allocator) if strings.contains(api, ",") else { api, }
            if len(list) > 0 && !slice.contains(list, "vulkan") {
                continue
            }
        }

        append(features_table, process_feature2(doc, feature, types_table[:], enums_table[:], commands_table[:]))
    }
}

main :: proc() {
    doc, err := xml.load_from_file("./Vulkan-Docs/xml/vk.xml", {flags={.Ignore_Unsupported, .Unbox_CDATA, .Decode_SGML_Entities}})
    defer xml.destroy(doc)
    assert(err == .None)

    extensions := get_extension_tags(doc)

    formats_table_id, has_formats_table := xml.find_child_by_ident(doc, 0, "formats")
    assert(has_formats_table)

    types_table := make([dynamic]Type2, context.temp_allocator)
    enums_table := make([dynamic]Enum2, context.temp_allocator)
    commands_table := make([dynamic]Command2, context.temp_allocator)
    extensions_table := make([dynamic]Extension2, context.temp_allocator)
    formats_table := make([dynamic]Format, context.temp_allocator)
    features_table := make([dynamic]Feature2, context.temp_allocator)

    process_enums(doc, &enums_table, &types_table)
    process_types(doc, &types_table, &enums_table)
    process_commands(doc, &commands_table, &types_table)
    process_extensions(doc, &extensions_table, &types_table, &enums_table, &commands_table)
    process_features(doc, &features_table, &extensions_table, &types_table, &enums_table, &commands_table)

    for id in xml_gather_children_with_ident(doc, formats_table_id, "format") {
        info, good := process_format(doc, id, formats_table[:], enums_table[:])
        assert(good)

        append(&formats_table, info)
    }

    generate_defines(doc, types_table[:], enums_table[:])
    generate_enums2(extensions, types_table[:], enums_table[:])
    generate_types2(doc, types_table[:], extensions_table[:], enums_table[:])
    generate_procs2(commands_table[:], types_table[:], extensions_table[:], enums_table[:])
    generate_formats(extensions, formats_table[:], enums_table[:])

    fmt.println("DONE")

}