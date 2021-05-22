require "./spec_helper"

describe Parser do
  it "parses define" do
    nodes = parse("#define FOO 1")
    define = nodes.last.as(Define)
    define.name.should eq("FOO")
    define.value.should eq("1")
  end

  it "parses define with operator" do
    nodes = parse("#define FOO 1 << 2")
    define = nodes.last.as(Define)
    define.name.should eq("FOO")
    define.value.should eq("1<<2")
  end

  it "parses define where a macro call follows" do
    nodes = parse("#define BAR extern\n#define FOO 1\nBAR int x;")
    define = nodes[-2].as(Define)
    define.name.should eq("FOO")
    define.value.should eq("1")
  end

  it "parses define with ((void*)-2) " do
    nodes = parse("#define FOO ((void*)-2)")
    define = nodes.last.as(Define)
    define.name.should eq("FOO")
    define.value.should eq("((void*)-2)")
  end

  it "parses variable" do
    nodes = parse("int some_var;")
    var = nodes.last.as(Var)
    var.name.should eq("some_var")
    var.type.should eq(PrimitiveType.int)
  end

  it "parses function" do
    nodes = parse("int some_func(float x);")
    func = nodes.last.as(Function)
    func.name.should eq("some_func")
    func.return_type.should eq(PrimitiveType.int)
    args = func.args
    args.size.should eq(1)
    var = args.first
    var.name.should eq("x")
    var.type.should eq(PrimitiveType.new(PrimitiveType::Kind::Float))
  end

  it "parses function with arg without name" do
    nodes = parse("int some_func(float);")
    func = nodes.last.as(Function)
    func.args.first.name.should eq("")
    func.variadic?.should be_false
  end

  it "parses variadic function" do
    nodes = parse("int some_func(float, ...);")
    func = nodes.last.as(Function)
    func.variadic?.should be_true
  end

  it "parses function with function type" do
    nodes = parse("void some_func(int (*x)(float, char));")
    func = nodes.last.as(Function)
    func.name.should eq("some_func")
    func.return_type.should eq(PrimitiveType.void)
    args = func.args
    args.size.should eq(1)
    var = args.first
    var.name.should eq("x")
    var.type.should eq(FunctionType.new([PrimitiveType.float, PrimitiveType.char] of Type, PrimitiveType.int))
  end

  it "parses struct" do
    nodes = parse("struct point { int x; int y; };")
    type = nodes.last.as(StructOrUnion)
    type.kind.should eq(:struct)
    type.name.should eq("struct point")
    fields = type.fields
    fields.size.should eq(2)
  end

  it "parses struct with unexposed struct" do
    nodes = parse("struct point { struct foo* x; };")
    type = nodes.last.as(StructOrUnion)
    fields = type.fields
    fields.first.type.should eq(PointerType.new(UnexposedType.new("foo")))
  end

  it "parses struct with unexposed enum" do
    nodes = parse("struct point { enum { x, y } foo;  };")
    type = nodes.last.as(StructOrUnion)
    fields = type.fields
    node_ref = fields.first.type.as(NodeRef)
    enum_def = node_ref.node.as(CrystalLib::Enum)
    enum_def.values.size.should eq(2)
  end

  it "parses recursive struct" do
    nodes = parse("struct point { struct point* x; };")
    type = nodes.last.as(StructOrUnion)
    type.kind.should eq(:struct)
    type.name.should eq("struct point")
    fields = type.fields
    fields.size.should eq(1)
  end

  it "parses union" do
    nodes = parse("union point { int x; int y; };")
    type = nodes.last.as(StructOrUnion)
    type.kind.should eq(:union)
    type.name.should eq("union point")
    fields = type.fields
    fields.size.should eq(2)
  end

  it "parses unnamed struct" do
    nodes = parse("struct { int x; int y; };")
    type = nodes.last.as(StructOrUnion)
    type.kind.should eq(:struct)
    type.name.should eq("")
    fields = type.fields
    fields.size.should eq(2)
  end

  it "parses struct with nested struct" do
    nodes = parse("struct point { struct { int x; int y; } nested; };")
    type = nodes.last.as(StructOrUnion)
    type.kind.should eq(:struct)
    type.name.should eq("struct point")
    fields = type.fields
    fields.size.should eq(1)

    subtype = fields[0].type.as(NodeRef)
    subtype = subtype.node.as(StructOrUnion)
    subtype.kind.should eq(:struct)
    fields = subtype.fields
    fields.size.should eq(2)
    fields[0].name.should eq("x")
    fields[0].type.should eq(PrimitiveType.int)
    fields[1].name.should eq("y")
    fields[1].type.should eq(PrimitiveType.int)
  end

  it "parses typedef" do
    nodes = parse("typedef int foo;")
    typedef = nodes.last.as(Typedef)
    typedef.name.should eq("foo")
    typedef.type.should eq(PrimitiveType.int)
  end

  it "parses typedef struct" do
    nodes = parse("struct foo { int x; int y; }; typedef struct foo point;")
    type = nodes.last.as(Typedef)
    type.name.should eq("point")
    node_ref = type.type.as(NodeRef)
    str = node_ref.node.as(StructOrUnion)
    fields = str.fields
    fields.size.should eq(2)
  end

  it "parses typedef struct" do
    nodes = parse("typedef struct { int x; int y; } point;")
    type = nodes.last.as(Typedef)
    type.name.should eq("point")
    node_ref = type.type.as(NodeRef)
    str = node_ref.node.as(StructOrUnion)
    fields = str.fields
    fields.size.should eq(2)
  end

  it "parses typedef enum" do
    nodes = parse("typedef enum { x, y } point;")
    type = nodes.last.as(Typedef)
    type.name.should eq("point")
    node_ref = type.type.as(NodeRef)
    enum_def = node_ref.node.as(CrystalLib::Enum)
    enum_def.values.size.should eq(2)
  end

  it "parses typedef function" do
    nodes = parse("typedef int foo(float);")
    typedef = nodes.last.as(Typedef)
    typedef.name.should eq("foo")
    typedef.type.should eq(FunctionType.new([PrimitiveType.float] of Type, PrimitiveType.int))
  end

  it "parses enum" do
    nodes = parse("enum colors { red, green = 10, blue };")
    enum_decl = nodes.last.as(CrystalLib::Enum)
    enum_decl.name.should eq("colors")
    enum_decl.type.should eq(PrimitiveType.new(PrimitiveType::Kind::UInt))
    values = enum_decl.values
    values.size.should eq(3)

    values[0].name.should eq("red")
    values[0].value.should eq(0)

    values[1].name.should eq("green")
    values[1].value.should eq(10)

    values[2].name.should eq("blue")
    values[2].value.should eq(11)
  end

  it "parses forward declared struct" do
    nodes = parse("struct point; typedef struct point spoint; struct point { int x; };")
    typedef_type = nodes[-2].as(Typedef)
    node_ref = (typedef_type.type.as(NodeRef))
    node = node_ref.node.as(StructOrUnion)
    node.name.should eq("struct point")
    node.fields.size.should eq(1)
  end

  describe "types" do
    it "parses primitive" do
      nodes = parse("int some_var;")
      var = nodes.last.as(Var)
      var.name.should eq("some_var")
      var.type.should eq(PrimitiveType.int)
    end

    it "parses pointer" do
      nodes = parse("int* some_var;")
      var = nodes.last.as(Var)
      var.name.should eq("some_var")
      var.type.should eq(PointerType.new(PrimitiveType.int))
    end

    it "parses typedef" do
      nodes = parse("typedef int foo; foo some_var;")
      var = nodes.last.as(Var)
      var.name.should eq("some_var")
      var.type.should eq(TypedefType.new("foo", PrimitiveType.int))
    end

    it "parses constant array" do
      nodes = parse("int some_var[2];")
      var = nodes.last.as(Var)
      var.name.should eq("some_var")
      var.type.should eq(ConstantArrayType.new(PrimitiveType.int, 2))
    end

    # This changes between clang versions so we don't test it
    # it "parses incomplete array" do
    #   nodes = parse("int some_var[];")
    #   var = nodes.last.as(Var)
    #   var.name.should eq("some_var")
    #   var.type.should eq(ConstantArrayType.new(PrimitiveType.int, 1))
    # end

    it "parses function" do
      nodes = parse("int (*tester)(float, char) = 0;")
      var = nodes.last.as(Var)
      var.name.should eq("tester")
      var.type.should eq(FunctionType.new([PrimitiveType.float, PrimitiveType.char] of Type, PrimitiveType.int))
    end

    it "parses single line brief comments" do
      source = <<-EOS
        /// some comment
        ///
        /// some other comment
        int some_func(float x);
      EOS
      nodes = parse(source, options: Parser::Option::ImportBriefComments)
      var = nodes.last.as(Function)
      var.doc.should eq("some comment")
    end

    it "parses single line full comments" do
      source = <<-EOS
        //! some comment
        //!
        //! some other comment
        int some_func(float x);
      EOS
      nodes = parse(source, options: Parser::Option::ImportFullComments)
      var = nodes.last.as(Function)
      var.doc.should eq("some comment\n\nsome other comment")
    end

    it "parses javadoc line brief comments" do
      source = <<-EOS
        /**
           some comment

           some other comment
         */
        int some_func(float x);
      EOS
      nodes = parse(source, options: Parser::Option::ImportBriefComments)
      var = nodes.last.as(Function)
      var.doc.should eq("some comment")
    end

    it "parses single line full comments" do
      source = <<-EOS
        /*!
         * some comment
         *
         * some other comment
         */
        int some_func(float x);
      EOS
      nodes = parse(source, options: Parser::Option::ImportFullComments)
      var = nodes.last.as(Function)
      var.doc.should eq("some comment\n\nsome other comment")
    end
  end
end
