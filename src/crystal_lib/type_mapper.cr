class CrystalLib::TypeMapper
  record PendingStruct,
    crystal_node : Crystal::CStructOrUnionDef,
    clang_type : CrystalLib::StructOrUnion,
    original_name : String

  getter pending_definitions
  getter predefined_structs_or_unions

  @typedef_name : String?

  def initialize(@prefix_matcher : PrefixMatcher? = nil)
    @pending_definitions = [] of Crystal::ASTNode
    @pending_structs = [] of PendingStruct
    @generated = {} of UInt64 => Crystal::ASTNode
    @predefined_structs_or_unions = [] of Crystal::CStructOrUnionDef

    # When completing a struct's fields we keep that struct and the field name in
    # case we find a nested struct, such as in:#
    #
    # struct foo {
    #   struct {
    #     int x;
    #   } point;
    # };
    #
    # In that case we want to generate Foo and FooPoint structs.
    @structs_stack = [] of {PendingStruct, String}
  end

  def map(type)
    map_non_recursive(type).tap { expand_pending_structs }
  end

  def map_non_recursive(type)
    @generated[type.object_id] ||= map_internal(type)
  end

  def map_internal(type : PrimitiveType)
    case type.kind
    when .void?
      path "Void"
    when .char_s?, .s_char?
      path ["LibC", "Char"]
    when .u_char?
      path ["UInt8"]
    when PrimitiveType::Kind::Bool,
         PrimitiveType::Kind::Int,
         PrimitiveType::Kind::Short,
         PrimitiveType::Kind::Long,
         PrimitiveType::Kind::LongLong,
         PrimitiveType::Kind::UInt,
         PrimitiveType::Kind::UShort,
         PrimitiveType::Kind::ULong,
         PrimitiveType::Kind::ULongLong,
         PrimitiveType::Kind::Float,
         PrimitiveType::Kind::Double,
         PrimitiveType::Kind::LongDouble,
         PrimitiveType::Kind::WChar
      path ["LibC", type.kind.to_s]
    else
      raise "Unsupported primitive kind: #{type.kind}"
    end
  end

  def map_internal(type : PointerType)
    pointee_type = type.type

    # Check the case of a pointer to an opaque struct
    if opaque_type = opaque_typedef?(pointee_type)
      return declare_typedef(opaque_type.name, pointer_type(path("Void")))
    end

    pointer_type(map_non_recursive(type.type))
  end

  def map_internal(type : BlockPointerType)
    pointer_type(map_non_recursive(type.type))
  end

  def map_internal(type : TypedefType)
    if type.name == "size_t"
      return path ["LibC", "SizeT"]
    end

    # Check the case of a typedef to a pointer to an opaque struct
    internal_type = type.type
    if internal_type.is_a?(PointerType) && opaque?(internal_type.type)
      return declare_typedef(type.name, pointer_type(path("Void")))
    end

    if internal_type.is_a?(NodeRef)
      internal_node = internal_type.node
      @typedef_name = type.name
      mapped = map_non_recursive(internal_node)
      @typedef_name = nil

      if internal_type.node.name.empty? || type.name == internal_type.node.unscoped_name
        return mapped
      end

      declare_typedef(type.name, mapped)
    else
      mapped = map_non_recursive(internal_type)
      declare_alias(type.name, mapped)
    end
  end

  def map_internal(type : FunctionType)
    inputs = type.inputs.map { |input| map_non_recursive(input).as(Crystal::ASTNode) }
    output = map_non_recursive(type.output)
    Crystal::ProcNotation.new(inputs, output)
  end

  def map_internal(type : ConstantArrayType)
    element_type = map_non_recursive(type.type)
    size = (type.size < Int32::MAX ? type.size.to_i32 : type.size)
    generic(path("StaticArray"), [element_type, Crystal::NumberLiteral.new(size)] of Crystal::ASTNode)
  end

  def map_internal(type : IncompleteArrayType)
    element_type = map_non_recursive(type.type)
    pointer_type(element_type)
  end

  def map_internal(type : NodeRef)
    map_non_recursive(type.node)
  end

  def map_internal(type : CrystalLib::Enum)
    enum_name = crystal_type_name(check_anonymous_name(type.name))

    # try to find out the type of the enum
    # (see https://stackoverflow.com/a/1113869)
    if type.values.all? { |v| Int32::MIN <= v.value <= Int32::MAX }
      base_type = Int32
    else # default type
      base_type = Int64
    end

    enum_members = type.values.map do |value|
      val = value.value
      if base_type == Int32 && !val.is_a?(Int32)
        val = val.to_i32
      elsif base_type == Int64 && !val.is_a?(Int64)
        val = val.to_i64
      end

      Crystal::Arg.new(crystal_type_name(value.name), default_value: Crystal::NumberLiteral.new(val)).tap(&.doc = value.doc).as(Crystal::ASTNode)
    end

    # default type of crystal enum: keep it implicit
    if base_type == Int32
      base_type = nil
    else
      base_type = path(base_type.to_s)
    end

    enum_def = Crystal::EnumDef.new(path([enum_name]), enum_members, base_type: base_type).tap(&.doc = type.doc)
    @pending_definitions << enum_def
    path(enum_name)
  end

  def map_internal(type : CrystalLib::StructOrUnion)
    untouched_struct_name = check_anonymous_name(type.unscoped_name)
    struct_name = crystal_type_name(untouched_struct_name)

    # Try finding a struct or union that has already been defined. If such
    # a struct/union exist, use their definition instead and don't insert anything
    found_predefined = @predefined_structs_or_unions.find { |predefined| predefined.name == struct_name }
    if found_predefined
      struct_def = found_predefined
    else
      if type.fields.empty?
        # For an empty struct we just return an alias to Void
        struct_def = Crystal::Alias.new(path(struct_name), path(["Void"])).tap(&.doc = type.doc)
      else
        struct_def = Crystal::CStructOrUnionDef.new(struct_name, union: type.kind == :union).tap(&.doc = type.doc)

        # Leave struct body for later, because of possible recursiveness
        @pending_structs << PendingStruct.new(struct_def, type, untouched_struct_name)
      end

      @pending_definitions << struct_def unless @generated.has_key?(type.object_id)
    end

    path(struct_name)
  end

  def map_internal(type : UnexposedType)
    path("Void")
  end

  def map_internal(type : VaListType)
    path ["LibC", "VaList"]
  end

  def map_internal(type : ErrorType)
    raise "Couldn't import type: #{type}"
  end

  def map_internal(type)
    raise "Unsupported type: #{type}, #{type.class}"
  end

  def opaque_typedef?(type)
    type.is_a?(TypedefType) && opaque?(type.type) ? type : nil
  end

  def opaque?(type)
    return unless type.is_a?(NodeRef)

    other_node = type.node
    (other_node.is_a?(StructOrUnion) && other_node.fields.empty?) ? type : nil
  end

  def pointer_type(element_type)
    generic(path("Pointer"), element_type)
  end

  def generic(name, args)
    Crystal::Generic.new(name, args)
  end

  def path(path)
    Crystal::Path.new(path)
  end

  def check_anonymous_name(name)
    return name unless name.empty?

    typedef_name = @typedef_name
    return typedef_name if typedef_name

    unless @structs_stack.empty?
      pending_struct, name = @structs_stack.last
      return "#{pending_struct.original_name}_#{name}"
    end

    raise "Bug: missing struct name"
  end

  def declare_alias(name, type)
    crystal_name = crystal_type_name(name)
    @pending_definitions << Crystal::Alias.new(path(crystal_name), type).tap(&.doc = type.doc)
    path(crystal_name)
  end

  def declare_typedef(name, type)
    crystal_name = crystal_type_name(name)
    @pending_definitions << Crystal::TypeDef.new(crystal_name, type).tap(&.doc = type.doc)
    path(crystal_name)
  end

  def expand_pending_structs
    while pending_struct = @pending_structs.pop?
      fields = pending_struct.clang_type.fields.map do |field|
        @structs_stack.push({pending_struct, field.name})
        arg = Crystal::Arg.new(crystal_field_name(field.name), restriction: map(field.type)).tap(&.doc = field.doc).as(Crystal::ASTNode)
        @structs_stack.pop
        arg
      end
      pending_struct.crystal_node.body = Crystal::Expressions.from(fields)
    end
  end

  def crystal_type_name(name)
    name = match_prefix(name)

    underscore_index = nil
    name.each_char_with_index do |char, i|
      break if char != '_'
      underscore_index = i
    end

    if underscore_index
      name = name[underscore_index + 1..-1]
    end

    name = name.underscore.camelcase

    if underscore_index
      name = String.build do |str|
        str << 'X'
        (underscore_index + 1).times { str << '_' }
        str << name
      end
    end

    name
  end

  def crystal_arg_name(name)
    crystal_field_name(name)
  end

  def crystal_fun_name(name)
    crystal_field_name(name)
  end

  def crystal_field_name(name)
    name = match_prefix(name).underscore
    name = "_end" if name == "end"
    name
  end

  def match_prefix(name)
    @prefix_matcher.try(&.match(name)) || name
  end
end
