require "clang"
require "clang/clang-c/Index"

class CrystalLib::Parser
  getter nodes

  @[Flags]
  enum Option
    ImportBriefComments
    ImportFullComments
  end

  def self.parse(source, flags = [] of String, options = Option::None)
    parser = Parser.new(source, flags, options)
    parser.parse
    nodes = parser.nodes
    # puts nodes.map(&.to_s).join("\n")
    nodes
  end

  @tu : Clang::TranslationUnit

  def initialize(@source : String, flags = [] of String, @options = Option::None)
    @nodes = [] of ASTNode
    @cursor_hash_to_node = {} of UInt32 => ASTNode
    @idx = Clang::Index.new
    Clang.default_c_include_directories(flags)
    @tu = Clang::TranslationUnit.from_source(
      @idx,
      [Clang::UnsavedFile.new("input.c", source)],
      flags,
      Clang::TranslationUnit.default_options |
      Clang::TranslationUnit::Options::IncludeBriefCommentsInCodeCompletion
    )
  end

  def parse
    @tu.cursor.visit_children do |cursor|
      node = visit(cursor)
      if node
        node.doc = generate_comments(cursor)
        @nodes << node
        Clang::ChildVisitResult::Continue
      else
        Clang::ChildVisitResult::Recurse
      end
    end
  end

  def generate_comments(cursor)
    if @options.import_full_comments?
      cursor.raw_comment_text.try do |comment|
        # Convert Doxygen comments
        # (see http://www.doxygen.nl/manual/docblocks.html)
        comment.gsub(Regex.union(
          /\/\*[\*!]\h*/m,     # Javadoc/Qt style comment block opening
          /\s*\*\/\Z/,         # Javadoc/Qt style comment block closing
          /^\s*\*\h*/m,        # Javadoc/Qt style inner block prefix
          /^\s*\/\/[\/!]\h*/m, # Single line comment block
        ), "").strip
      end
    elsif @options.import_brief_comments?
      cursor.brief_comment_text
    end
  end

  def visit(cursor)
    case cursor.kind
    when .macro_definition?
      visit_macro_definition(cursor)
    when .var_decl?
      visit_var_declaration(cursor)
    when .function_decl?
      visit_function_declaration(cursor)
    when .struct_decl?
      visit_struct_or_union_declaration(cursor, :struct)
    when .union_decl?
      visit_struct_or_union_declaration(cursor, :union)
    when .typedef_decl?
      visit_typedef_declaration(cursor)
    when .enum_decl?
      visit_enum_declaration(cursor)
    else
      # puts "#{cursor.kind}: #{cursor.spelling}"

    end
  end

  def visit_macro_definition(cursor)
    name = name(cursor)
    value = macro_definition_value(cursor)
    Define.new(name, value)
  end

  def macro_definition_value(cursor)
    value = String.build do |str|
      first = true
      old_line = nil
      @tu.tokenize(cursor.extent) do |token|
        # Sometimes the tokenizations goes beyond one line (bug in clang?),
        # so we only get the define's value of a single line
        line = token.location.file_location[1]
        break if old_line != nil && old_line != line
        old_line = line

        if first
          first = false
          next
        end

        case token.kind
        when LibC::CXTokenKind::Literal
          str << token.spelling
        when LibC::CXTokenKind::Punctuation
          spelling = token.spelling
          break if spelling == "#"
          str << spelling
        when LibC::CXTokenKind::Identifier,
             LibC::CXTokenKind::Keyword
          spelling = token.spelling
          str << spelling
        else
          # Nothing

        end
      end
    end
    value.strip
  end

  def visit_var_declaration(cursor)
    name = name(cursor)
    type = type(cursor.type)
    Var.new(name, type)
  end

  def visit_param_declaration(cursor)
    name = name(cursor)
    type = type(cursor.type)
    Arg.new(name, type).tap(&.doc = generate_comments(cursor))
  end

  def visit_typedef_declaration(cursor)
    name = cursor.spelling
    type = type(cursor.typedef_decl_underlying_type)
    named_types[name] = TypedefType.new(name, type)
    Typedef.new(name, type)
  end

  def visit_function_declaration(cursor)
    variadic = cursor.variadic?

    name = name(cursor)
    return_type = type(cursor.result_type)
    function = Function.new(name, return_type, variadic)

    cursor.visit_children do |subcursor|
      if subcursor.kind == Clang::CursorKind::ParmDecl
        function.args << visit_param_declaration(subcursor)
      end

      Clang::ChildVisitResult::Continue
    end

    function
  end

  def visit_struct_or_union_declaration(cursor, kind)
    name = name(cursor)

    struct_or_union = StructOrUnion.new(kind, name)

    unless name.empty?
      full_name = "#{kind} #{name}"
      if (existing = named_nodes[full_name]?) && existing.is_a?(StructOrUnion)
        struct_or_union = existing
      else
        named_nodes[full_name] = struct_or_union
      end
    end

    @cursor_hash_to_node[cursor.hash] = struct_or_union

    cursor.visit_children do |subcursor|
      if subcursor.kind == Clang::CursorKind::FieldDecl
        var = visit_var_declaration(subcursor)
        unless struct_or_union.fields.any? { |v| v.name == var.name }
          struct_or_union.fields << var.tap(&.doc = generate_comments(subcursor))
        end
      end

      Clang::ChildVisitResult::Continue
    end

    struct_or_union
  end

  def visit_enum_declaration(cursor)
    name = name(cursor)

    type = type(cursor.enum_decl_integer_type)
    enum_decl = Enum.new(name, type)

    @cursor_hash_to_node[cursor.hash] = enum_decl

    cursor.visit_children do |subcursor|
      if subcursor.kind == Clang::CursorKind::EnumConstantDecl
        enum_decl.values << visit_enum_constant_declaration(subcursor)
      end

      Clang::ChildVisitResult::Continue
    end

    enum_decl
  end

  def visit_enum_constant_declaration(cursor)
    EnumValue.new(cursor.spelling, cursor.enum_constant_decl_value).tap(&.doc = generate_comments(cursor))
  end

  def name(cursor)
    name = cursor.spelling
    name = "" if name.empty?
    name
  end

  def type(type)
    case type.kind
    when Clang::TypeKind::Pointer
      pointee_type = type.pointee_type

      # Check the case of a function pointer type. I couldn't find another one to do this
      # other than checking the result type, and if it's not invalid it means it's a function
      result_type = pointee_type.result_type
      if result_type.kind != Clang::TypeKind::Invalid
        return build_function_type(pointee_type, result_type)
      end

      pointer_type(type(pointee_type))
    when Clang::TypeKind::FunctionProto
      build_function_type type
    when Clang::TypeKind::BlockPointer
      block_pointer_type(type(type.pointee_type))
    when Clang::TypeKind::ConstantArray
      constant_array_type(type(type.array_element_type), type.array_size)
    when Clang::TypeKind::IncompleteArray
      incomplete_array_type(type(type.array_element_type))
    when Clang::TypeKind::Typedef
      spelling = type.spelling
      spelling = spelling.gsub("const ", "").gsub("volatile ", "")
      if !named_types.has_key?(spelling) && spelling == "__builtin_va_list"
        VaListType.new
      else
        named_types[spelling]? || error_type(spelling)
      end
    when Clang::TypeKind::Unexposed,
         Clang::TypeKind::Elaborated
      existing = @cursor_hash_to_node[type.cursor.hash]?
      if existing
        NodeRef.new(existing)
      elsif existing = named_nodes[type.spelling]?
        NodeRef.new(existing)
      else
        definition = type.cursor.definition
        case definition.kind
        when .struct_decl?
          NodeRef.new(visit_struct_or_union_declaration(definition, :struct))
        when .union_decl?
          NodeRef.new(visit_struct_or_union_declaration(definition, :union))
        when .enum_decl?
          NodeRef.new(visit_enum_declaration(definition))
        else
          UnexposedType.new(type.cursor.spelling)
        end
      end
    when Clang::TypeKind::Void,
         Clang::TypeKind::Bool,
         Clang::TypeKind::Char_S,
         Clang::TypeKind::SChar,
         Clang::TypeKind::UChar,
         Clang::TypeKind::Int,
         Clang::TypeKind::Short,
         Clang::TypeKind::Long,
         Clang::TypeKind::LongLong,
         Clang::TypeKind::UInt,
         Clang::TypeKind::UShort,
         Clang::TypeKind::ULong,
         Clang::TypeKind::ULongLong,
         Clang::TypeKind::Float,
         Clang::TypeKind::Double,
         Clang::TypeKind::LongDouble,
         Clang::TypeKind::WChar
      primitive_type(type.kind)
    when Clang::TypeKind::Record,
         Clang::TypeKind::Dependent,
         Clang::TypeKind::Auto
      # Skip these for now. If they are needed we'll analyze them at that time
      error_type(type.spelling)
    else
      raise "Don't know how to convert #{type.spelling} (#{type.kind})"
    end
  end

  def build_function_type(type, result_type = type.result_type)
    arg_types = type.arguments.map { |v| type(v).as(Type) }
    function_type(arg_types, type(result_type))
  end

  def primitive_types
    @primitive_types ||= {} of PrimitiveType::Kind => Type
  end

  def pointer_types
    @pointer_types ||= {} of UInt64 => Type
  end

  def block_pointer_types
    @block_pointer_types ||= {} of UInt64 => Type
  end

  def named_types
    @named_types ||= {} of String => Type
  end

  def named_nodes
    @named_nodes ||= {} of String => ASTNode
  end

  record ConstantArrayKey,
    object_id : UInt64, size : Int64

  def constant_array_types
    @constant_array_types ||= {} of ConstantArrayKey => Type
  end

  def incomplete_array_types
    @incomplete_array_types ||= {} of UInt64 => Type
  end

  record FunctionKey,
    inputs_ids : Array(UInt64),
    output_id : UInt64

  def function_types
    @function_types ||= {} of FunctionKey => Type
  end

  def error_types
    @error_types ||= {} of String => Type
  end

  def primitive_type(kind)
    kind = PrimitiveType::Kind.new(kind.value)
    primitive_types[kind] ||= PrimitiveType.new(kind)
  end

  def pointer_type(type)
    pointer_types[type.object_id] ||= PointerType.new(type)
  end

  def block_pointer_type(type)
    block_pointer_types[type.object_id] ||= BlockPointerType.new(type)
  end

  def constant_array_type(type, size)
    constant_array_types[ConstantArrayKey.new(type.hash, size)] ||= ConstantArrayType.new(type, size)
  end

  def incomplete_array_type(type)
    incomplete_array_types[type.object_id] ||= IncompleteArrayType.new(type)
  end

  def function_type(inputs, output)
    function_types[FunctionKey.new(inputs.map(&.hash), output.hash)] ||= FunctionType.new(inputs, output)
  end

  def error_type(name)
    error_types[name] ||= ErrorType.new(name)
  end
end
