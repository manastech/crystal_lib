require "compiler/crystal/syntax"

class CrystalLib::LibBodyTransformer < Crystal::Transformer
  def initialize(nodes : Array(CrystalLib::ASTNode))
    @nodes = nodes
    @mapper = TypeMapper.new
  end

  def transform(node : Crystal::FunDef)
    name = node.real_name
    func = find_node name

    while func.is_a?(CrystalLib::Define)
      func = find_node(func.value)
    end

    raise "can't find function #{name}" unless func.is_a?(CrystalLib::Function)

    node.doc = func.doc

    node.args = func.args.map_with_index do |arg, i|
      Crystal::Arg.new(arg.name.empty? ? "x#{i}" : @mapper.crystal_arg_name(arg.name), restriction: map_type(arg.type))
    end
    return_type = map_type(func.return_type)

    unless void?(return_type)
      node.return_type = return_type
    end

    node.varargs = func.variadic?

    check_pending_definitions(node)
  end

  def transform(node : Crystal::Assign)
    name = node.value.to_s
    match = find_node(name)
    raise "can't find constant #{name}" unless match.is_a?(Define)
    value = match.value

    if name == match.value
      # macro definition references an enum value
      if enum_value = find_enum_value(name)
        value = enum_value.value.to_s
      end
    end

    if value.size > 1 && value[0] == '0' && value[1] != 'x'
      value = "0o#{value[1..-1]}"
    end

    node.doc = match.doc

    begin
      node.value = Crystal::Parser.parse(value)
    rescue ex : Crystal::CodeError
      raise "can't parse value of constant #{name}: #{value}"
    end
    node
  end

  private def find_enum_value(name)
    @nodes.each do |node|
      next unless node.is_a?(CrystalLib::Enum)
      node.values.each do |enum_value|
        return enum_value if enum_value.name == name
      end
    end
    nil
  end

  def transform(node : Crystal::ExternalVar)
    name = node.real_name || node.name

    match = find_node(name)
    raise "can't find variable #{name}" unless match.is_a?(CrystalLib::Var)

    node.doc = match.doc

    node.type_spec = map_type(match.type)
    check_pending_definitions(node)
  end

  def transform(node : Crystal::CStructOrUnionDef)
    @mapper.predefined_structs_or_unions << node

    # There will be no pending definitions, since the node will
    # be skipped and replaced with the current one when going through
    # its usage in the header
    node
  end

  def map_type(type)
    @mapper.map(type)
  end

  def find_node(name)
    @nodes.find { |node| node.name == name }
  end

  def check_pending_definitions(node)
    return node if @mapper.pending_definitions.empty?

    nodes = @mapper.pending_definitions.dup
    nodes << node

    @mapper.pending_definitions.clear

    Crystal::Expressions.new(nodes)
  end

  def void?(node)
    node.is_a?(Crystal::Path) && node.names.size == 1 && node.names.first == "Void"
  end
end
