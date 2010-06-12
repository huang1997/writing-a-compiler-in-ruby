
# See Symbol for a discussion of type tagging.
#
# FIXME: For (right) now String objects are sort-of immutable.
# At least #concat needs to be implemented for our needed
# use in #attr_writer.
class String
  def initialize
    # @buffer contains the pointer to raw memory
    # used to contain the string.
    # 
    # An s-expression is used rather than = because
    # 0 outside of the s-expression eventually will
    # be an FixNum instance instead of the actual
    # value 0.
    %s(assign @buffer 0)
  end

  def __set_raw(str)
    @buffer = str
  end

  def __get_raw
    @buffer
  end

  def each_byte
  end

  def uniq
  end

  def to_s
  end

  def to_sym
    buffer = @buffer
    %s(call __get_symbol buffer)
  end

  def to_i
  end

  def slice!
  end

  def reverse
  end

  def length
  end

  def count
  end
end

# FIXME: This is an interesting bootstrapping problem
# __get_string can only be called from an s-expression,
# since otherwise "str" will get rewritten to __get_string(str)
# if str is a string constant.
#
# It is still not a satisfactory solution: It ought to never
# be possible to call __set_raw or __get_string directly from
# "normal" Ruby code. Or at the very least a nasty warning
# should be generated. A solution for that might be a pragma
# like the one below (hypothetical, not implemented, indicating
# the call should only be allowed for code generated by the
# compiler)
#
# Another alternative is to implement
#
# pragma compiler-only
%s(defun __get_string (str) (let (s)
  (assign s (callm String new))
  (callm s __set_raw (str))
  s
))
