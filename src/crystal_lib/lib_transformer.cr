class CrystalLib::LibTransformer < Crystal::Transformer
  def initialize
    @includes = [] of Crystal::Annotation
  end

  def transform(node : Crystal::Annotation)
    case node.path.names
    when ["Include"]
      @includes << node
      Crystal::Nop.new
    else
      node
    end
  end

  def transform(node : Crystal::LibDef)
    headers, flags, prefixes, remove_prefix, options = process_includes
    nodes = CrystalLib::Parser.parse(headers, flags, options)

    if prefixes.empty?
      node.body = node.body.transform CrystalLib::LibBodyTransformer.new(nodes)
    else
      prefix_matcher = PrefixMatcher.new(prefixes, remove_prefix)
      node.body = CrystalLib::PrefixImporter.import(nodes, prefix_matcher)
    end

    node
  end

  def process_includes
    headers = IO::Memory.new
    flags = [] of String
    options = CrystalLib::Parser::Option::None
    prefixes = [] of String
    remove_prefix = true

    @includes.each do |attr|
      attr.args.each do |arg|
        case arg
        when Crystal::StringLiteral
          headers << "#include <" << arg.value << ">\n"
        else
          raise "Include attribute value must be a string literal, at #{arg.location}"
        end
      end
      attr.named_args.try &.each do |named_arg|
        case named_arg.name
        when "flags"
          value = named_arg.value
          case value
          when Crystal::StringLiteral
            flags.concat(value.value.split(' '))
          else
            raise "Include flags value must be a string literal, at #{value.location}"
          end
        when "prefix"
          value = named_arg.value
          case value
          when Crystal::StringLiteral
            prefixes << value.value
          when Crystal::ArrayLiteral
            value.elements.each do |value2|
              case value2
              when Crystal::StringLiteral
                prefixes << value2.value
              else
                raise "Include prefix value must be a string literal or array literal of string literals, at #{value.location}"
              end
            end
          else
            raise "Include prefix value must be a string literal or array literal, at #{value.location}"
          end
        when "remove_prefix"
          value = named_arg.value
          case value
          when Crystal::BoolLiteral
            remove_prefix = value.value
          else
            raise "Include remove_prefix value must be a bool literal, at #{value.location}"
          end
        when "import_docstrings"
          value = named_arg.value
          case value
          when Crystal::StringLiteral, Crystal::BoolLiteral
            case value.value
            when "brief"
              options |= CrystalLib::Parser::Option::ImportBriefComments
            when "full", true
              options |= CrystalLib::Parser::Option::ImportFullComments
            when "none", false
            else
              raise "Include import_docstrings value must be \"brief\", \"full\", \"none\", true or false at #{value.location}"
            end
          else
            raise "Include comments value must be a string or bool literal, at #{value.location}"
          end
        else
          raise "unknown named argument for Include attribtue, at #{named_arg.location}"
        end
      end
    end

    {headers.to_s, flags, prefixes, remove_prefix, options}
  end
end
