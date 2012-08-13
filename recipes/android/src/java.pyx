'''
Java wrapper
============

With this module, you can create Python class that reflect a Java class, and use
it directly in Python. For example, if you have a Java class named
Hardware.java, in org/test directory::

    public class Hardware {
        static int getDPI() {
            return metrics.densityDpi;
        }
    }

You can create this Python class to use it::

    class Hardware(JavaClass):
        __javaclass__ = 'org/test/Hardware'
        getDPI = JavaStaticMethod('()I')

And then, do::

    hardware = Hardware()
    hardware.getDPI()

Limitations
-----------

- Even if the method is static in Java, you need to instanciate the object in
  Python.
- Array currently not supported
'''

__all__ = ('JavaObject', 'JavaClass', 'JavaMethod', 'JavaStaticMethod',
    'JavaField', 'JavaStaticField')

include "jni.pxi"
from libc.stdlib cimport malloc, free


cdef parse_definition(definition):
    # not a function, just a field
    if definition[0] != '(':
        return definition, None

    # it's a function!
    argdef, ret = definition[1:].split(')')
    args = []

    while len(argdef):
        c = argdef[0]

        # read the array char
        prefix = ''
        if c == '[':
            prefix = c
            argdef = argdef[1:]
            c = argdef[0]

        # native type
        if c in 'ZBCSIJFD':
            args.append(prefix + c)
            argdef = argdef[1:]
            continue

        # java class
        if c == 'L':
            c, argdef = argdef.split(';', 1)
            args.append(prefix + c + ';')

    return ret, args

class JavaException(Exception):
    '''Can be a real java exception, or just an exception from the wrapper.
    '''
    pass


cdef class JavaObject(object):
    '''Can contain any Java object. Used to store instance, or whatever.
    '''

    cdef jobject obj

    def __cinit__(self):
        self.obj = NULL


cdef class JavaClass(object):
    '''Main class to do introspection.
    '''

    cdef JNIEnv *j_env
    cdef jclass j_cls
    cdef jobject j_self

    def __cinit__(self, *args):
        self.j_env = NULL
        self.j_cls = NULL
        self.j_self = NULL

    def __init__(self, *args):
        super(JavaClass, self).__init__()
        self.resolve_class()
        self.call_constructor(args)
        self.resolve_methods()
        self.resolve_fields()

    cdef void call_constructor(self, args):
        # the goal is to found the class constructor, and call it with the
        # correct arguments.
        cdef jvalue *j_args = NULL
        cdef jmethodID constructor = NULL

        # get the constructor definition if exist
        definition = '()V'
        if hasattr(self, '__javaconstructor__'):
            definition = self.__javaconstructor__
        self.definition = definition
        d_ret, d_args = parse_definition(definition)
        if len(args) != len(d_args):
            raise JavaException('Invalid call, number of argument'
                    ' mismatch for constructor')

        try:
            # convert python arguments to java arguments
            if len(args):
                j_args = <jvalue *>malloc(sizeof(jvalue) * len(d_args))
                if j_args == NULL:
                    raise MemoryError('Unable to allocate memory for java args')
                self.populate_args(d_args, j_args, args)

            # get the java constructor
            constructor = self.j_env[0].GetMethodID(
                self.j_env, self.j_cls, '<init>', <char *><bytes>definition)
            if constructor == NULL:
                raise JavaException('Unable to found the constructor'
                        ' for {0}'.format(self.__javaclass__))

            # create the object
            self.j_self = self.j_env[0].NewObjectA(self.j_env, self.j_cls,
                    constructor, j_args)
            if self.j_self == NULL:
                raise JavaException('Unable to instanciate {0}'.format(
                    self.__javaclass__))

        finally:
            if j_args != NULL:
                free(j_args)

    cdef void resolve_class(self):
        # search the Java class, and bind to our object
        if not hasattr(self, '__javaclass__'):
            raise JavaException('__javaclass__ definition missing')

        self.j_env = SDL_ANDROID_GetJNIEnv()
        if self.j_env == NULL:
            raise JavaException('Unable to get the Android JNI Environment')

        self.j_cls = self.j_env[0].FindClass(self.j_env,
                <char *><bytes>self.__javaclass__)
        if self.j_cls == NULL:
            raise JavaException('Unable to found the class'
                    ' {0}'.format(self.__javaclass__))

    cdef void resolve_methods(self):
        # search all the JavaMethod within our class, and resolve them
        cdef JavaMethod jm
        for name in dir(self.__class__):
            value = getattr(self.__class__, name)
            if not isinstance(value, JavaMethod):
                continue
            jm = value
            jm.resolve_method(self, name)

    cdef void resolve_fields(self):
        # search all the JavaField within our class, and resolve them
        cdef JavaField jf
        for name in dir(self.__class__):
            value = getattr(self.__class__, name)
            if not isinstance(value, JavaField):
                continue
            jf = value
            jf.resolve_field(self, name)

    cdef void populate_args(self, list definition_args, jvalue *j_args, args):
        # do the conversion from a Python object to Java from a Java definition
        cdef JavaObject jo
        cdef JavaClass jc
        cdef int index
        for index, argtype in enumerate(definition_args):
            py_arg = args[index]
            if argtype == 'Z':
                j_args[index].z = py_arg
            elif argtype == 'B':
                j_args[index].b = py_arg
            elif argtype == 'C':
                j_args[index].c = ord(py_arg)
            elif argtype == 'S':
                j_args[index].s = py_arg
            elif argtype == 'I':
                j_args[index].i = py_arg
            elif argtype == 'J':
                j_args[index].j = py_arg
            elif argtype == 'F':
                j_args[index].f = py_arg
            elif argtype == 'D':
                j_args[index].d = py_arg
            elif argtype[0] == 'L':
                if py_arg is None:
                    j_args[index].l = NULL
                elif isinstance(py_arg, basestring) and \
                        argtype == 'Ljava/lang/String;':
                    j_args[index].l = self.j_env[0].NewStringUTF(
                            self.j_env, <char *><bytes>py_arg)
                elif isinstance(py_arg, JavaClass):
                    jc = py_arg
                    if jc.__javaclass__ != argtype[1:-1]:
                        raise JavaException('Invalid class argument, want '
                                '{0!r}, got {1!r}'.format(
                                    argtype[1:-1], jc.__javaclass__))
                    j_args[index].l = jc.j_self
                elif isinstance(py_arg, JavaObject):
                    jo = py_arg
                    j_args[index].l = jo.obj
                    raise JavaException('JavaObject needed for argument '
                            '{0}'.format(index))
                else:
                    raise JavaException('Invalid python object for this '
                            'argument. Want {0!r}, got {1!r}'.format(
                                argtype[1:-1], py_arg))
            elif argtype[0] == '[':
                if not isinstance(py_arg, list) and \
                        not isinstance(py_arg, tuple):
                    raise JavaException('Expecting a python list/tuple, got '
                            '{0!r}'.format(py_arg))

                j_args[index].l = self.convert_pyarray_to_java(
                        argtype[1:], py_arg)

    cdef jobject convert_pyarray_to_java(self, definition, pyarray):
        cdef jobject ret = NULL
        cdef int array_size = len(pyarray)
        cdef int i
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jstring j_string
        cdef jclass j_class
        cdef JavaObject jo
        cdef JavaClass jc

        if definition == 'Z':
            ret = self.j_env[0].NewBooleanArray(self.j_env, array_size)
            for i in range(array_size):
                j_boolean = 1 if pyarray[i] else 0
                self.j_env[0].SetBooleanArrayRegion(self.j_env,
                        ret, i, 1, &j_boolean)

        elif definition == 'B':
            ret = self.j_env[0].NewByteArray(self.j_env, array_size)
            for i in range(array_size):
                j_byte = pyarray[i]
                self.j_env[0].SetByteArrayRegion(self.j_env,
                        ret, i, 1, &j_byte)

        elif definition == 'C':
            ret = self.j_env[0].NewCharArray(self.j_env, array_size)
            for i in range(array_size):
                j_char = ord(pyarray[i])
                self.j_env[0].SetCharArrayRegion(self.j_env,
                        ret, i, 1, &j_char)

        elif definition == 'S':
            ret = self.j_env[0].NewShortArray(self.j_env, array_size)
            for i in range(array_size):
                j_short = pyarray[i]
                self.j_env[0].SetShortArrayRegion(self.j_env,
                        ret, i, 1, &j_short)

        elif definition == 'I':
            ret = self.j_env[0].NewIntArray(self.j_env, array_size)
            for i in range(array_size):
                j_int = pyarray[i]
                self.j_env[0].SetIntArrayRegion(self.j_env,
                        ret, i, 1, <const_jint *>&j_int)

        elif definition == 'J':
            ret = self.j_env[0].NewLongArray(self.j_env, array_size)
            for i in range(array_size):
                j_long = pyarray[i]
                self.j_env[0].SetLongArrayRegion(self.j_env,
                        ret, i, 1, &j_long)

        elif definition == 'F':
            ret = self.j_env[0].NewFloatArray(self.j_env, array_size)
            for i in range(array_size):
                j_float = pyarray[i]
                self.j_env[0].SetFloatArrayRegion(self.j_env,
                        ret, i, 1, &j_float)

        elif definition == 'D':
            ret = self.j_env[0].NewDoubleArray(self.j_env, array_size)
            for i in range(array_size):
                j_double = pyarray[i]
                self.j_env[0].SetDoubleArrayRegion(self.j_env,
                        ret, i, 1, &j_double)

        elif definition[0] == 'L':
            j_class = self.j_env[0].FindClass(
                    self.j_env, <bytes>definition[1:-1])
            if j_class == NULL:
                raise JavaException('Cannot create array with a class not '
                        'found {0!r}'.format(definition[1:-1]))
            ret = self.j_env[0].NewObjectArray(
                    self.j_env, array_size, j_class, NULL)
            for i in range(array_size):
                arg = pyarray[i]
                if arg is None:
                    self.j_env[0].SetObjectArrayElement(
                            self.j_env, <jobjectArray>ret, i, NULL)
                elif isinstance(arg, basestring) and \
                        definition == 'Ljava/lang/String;':
                    j_string = self.j_env[0].NewStringUTF(
                            self.j_env, <bytes>arg)
                    self.j_env[0].SetObjectArrayElement(
                            self.j_env, <jobjectArray>ret, i, j_string)
                elif isinstance(arg, JavaClass):
                    jc = arg
                    if jc.__javaclass__ != definition[1:-1]:
                        raise JavaException('Invalid class argument, want '
                                '{0!r}, got {1!r}'.format(
                                    definition[1:-1],
                                    jc.__javaclass__))
                    self.j_env[0].SetObjectArrayElement(
                            self.j_env, <jobjectArray>ret, i, jc.j_self)
                elif isinstance(arg, JavaObject):
                    jo = arg
                    self.j_env[0].SetObjectArrayElement(
                            self.j_env, <jobjectArray>ret, i, jo.obj)
                else:
                    raise JavaException('Invalid variable used for L array')

        else:
            raise JavaException('Invalid array definition')

        return <jobject>ret


    cdef convert_jarray_to_python(self, definition, jobject j_object):
        cdef jboolean iscopy
        cdef jboolean *j_booleans
        cdef jbyte *j_bytes
        cdef jchar *j_chars
        cdef jshort *j_shorts
        cdef jint *j_ints
        cdef jlong *j_longs
        cdef jfloat *j_floats
        cdef jdouble *j_doubles
        cdef object ret = None
        cdef jsize array_size

        cdef int i
        cdef jobject obj
        cdef char *c_str
        cdef bytes py_str
        cdef JavaObject ret_jobject

        if j_object == NULL:
            return None

        array_size = self.j_env[0].GetArrayLength(self.j_env, j_object)

        r = definition[0]
        if r == 'Z':
            j_booleans = self.j_env[0].GetBooleanArrayElements(
                    self.j_env, j_object, &iscopy)
            ret = [(True if j_booleans[i] else False)
                    for i in range(array_size)]
            if iscopy:
                self.j_env[0].ReleaseBooleanArrayElements(
                        self.j_env, j_object, j_booleans, 0)

        elif r == 'B':
            j_bytes = self.j_env[0].GetByteArrayElements(
                    self.j_env, j_object, &iscopy)
            ret = [(<char>j_bytes[i]) for i in range(array_size)]
            if iscopy:
                self.j_env[0].ReleaseByteArrayElements(
                        self.j_env, j_object, j_bytes, 0)

        elif r == 'C':
            j_chars = self.j_env[0].GetCharArrayElements(
                    self.j_env, j_object, &iscopy)
            ret = [(<char>j_chars[i]) for i in range(array_size)]
            if iscopy:
                self.j_env[0].ReleaseCharArrayElements(
                        self.j_env, j_object, j_chars, 0)

        elif r == 'S':
            j_shorts = self.j_env[0].GetShortArrayElements(
                    self.j_env, j_object, &iscopy)
            ret = [(<short>j_shorts[i]) for i in range(array_size)]
            if iscopy:
                self.j_env[0].ReleaseShortArrayElements(
                        self.j_env, j_object, j_shorts, 0)

        elif r == 'I':
            j_ints = self.j_env[0].GetIntArrayElements(
                    self.j_env, j_object, &iscopy)
            ret = [(<int>j_ints[i]) for i in range(array_size)]
            if iscopy:
                self.j_env[0].ReleaseIntArrayElements(
                        self.j_env, j_object, j_ints, 0)

        elif r == 'J':
            j_longs = self.j_env[0].GetLongArrayElements(
                    self.j_env, j_object, &iscopy)
            ret = [(<long>j_longs[i]) for i in range(array_size)]
            if iscopy:
                self.j_env[0].ReleaseLongArrayElements(
                        self.j_env, j_object, j_longs, 0)

        elif r == 'F':
            j_floats = self.j_env[0].GetFloatArrayElements(
                    self.j_env, j_object, &iscopy)
            ret = [(<float>j_floats[i]) for i in range(array_size)]
            if iscopy:
                self.j_env[0].ReleaseFloatArrayElements(
                        self.j_env, j_object, j_floats, 0)

        elif r == 'D':
            j_doubles = self.j_env[0].GetDoubleArrayElements(
                    self.j_env, j_object, &iscopy)
            ret = [(<double>j_doubles[i]) for i in range(array_size)]
            if iscopy:
                self.j_env[0].ReleaseDoubleArrayElements(
                        self.j_env, j_object, j_doubles, 0)

        elif r == 'L':
            ret = []
            if definition == 'Ljava/lang/String;':
                for i in range(array_size):
                    obj = self.j_env[0].GetObjectArrayElement(
                            self.j_env, j_object, i)
                    if obj == NULL:
                        ret.append(None)
                        continue
                    c_str = <char *>self.j_env[0].GetStringUTFChars(
                            self.j_env, obj, NULL)
                    py_str = <bytes>c_str
                    self.j_env[0].ReleaseStringUTFChars(
                            self.j_env, j_object, c_str)
                    ret.append(py_str)
            else:
                for i in range(array_size):
                    obj = self.j_env[0].GetObjectArrayElement(
                            self.j_env, j_object, i)
                    if obj == NULL:
                        ret.append(None)
                        continue
                    ret_jobject = JavaObject()
                    ret_jobject.obj = obj
                    ret.append(ret_jobject)
        else:
            raise JavaException('Invalid return definition for array')

        return ret


cdef class JavaField(object):
    cdef jfieldID j_field
    cdef JavaClass jc
    cdef JNIEnv *j_env
    cdef jclass j_cls
    cdef jobject j_self
    cdef bytes definition
    cdef object is_static

    def __cinit__(self, definition, **kwargs):
        self.j_field = NULL
        self.j_env = NULL
        self.j_cls = NULL

    def __init__(self, definition, **kwargs):
        super(JavaField, self).__init__()
        self.definition = definition
        self.is_static = kwargs.get('static', False)

    cdef resolve_field(self, JavaClass jc, bytes name):
        # called by JavaClass when we want to resolve the field name
        self.jc = jc
        self.j_env = jc.j_env
        self.j_cls = jc.j_cls
        self.j_self = jc.j_self
        if self.is_static:
            self.j_field = self.j_env[0].GetStaticFieldID(
                    self.j_env, self.j_cls, <char *>name,
                    <char *>self.definition)
        else:
            self.j_field = self.j_env[0].GetFieldID(
                    self.j_env, self.j_cls, <char *>name,
                    <char *>self.definition)

        if self.j_field == NULL:
            raise JavaException('Unable to found the field'
                    ' {0} in {1}'.format(name, jc.__javaclass__))

    def __get__(self, obj, objtype):
        if obj is None:
            return self
        if self.is_static:
            return self.read_static_field()
        return self.read_field()

    cdef read_field(self):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject

        # return type of the java method
        r = self.definition[0]

        # now call the java method
        if r == 'Z':
            j_boolean = self.j_env[0].GetBooleanField(
                    self.j_env, self.j_self, self.j_field)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].GetByteField(
                    self.j_env, self.j_self, self.j_field)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].GetCharField(
                    self.j_env, self.j_self, self.j_field)
            ret = chr(<char>j_char)
        elif r == 'S':
            j_short = self.j_env[0].GetShortField(
                    self.j_env, self.j_self, self.j_field)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].GetIntField(
                    self.j_env, self.j_self, self.j_field)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].GetLongField(
                    self.j_env, self.j_self, self.j_field)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].GetFloatField(
                    self.j_env, self.j_self, self.j_field)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].GetDoubleField(
                    self.j_env, self.j_self, self.j_field)
            ret = <double>j_double
        elif r == 'L':
            j_object = self.j_env[0].GetObjectField(
                    self.j_env, self.j_self, self.j_field)
            if j_object == NULL:
                return None
            if self.definition == 'Ljava/lang/String;':
                c_str = <char *>self.j_env[0].GetStringUTFChars(
                        self.j_env, j_object, NULL)
                py_str = <bytes>c_str
                self.j_env[0].ReleaseStringUTFChars(
                        self.j_env, j_object, c_str)
                ret = py_str
            else:
                ret_jobject = JavaObject()
                ret_jobject.obj = j_object
                ret = ret_jobject
        elif r == '[':
            r = self.definition[1:]
            j_object = self.j_env[0].GetObjectField(
                    self.j_env, self.j_self, self.j_field)
            ret = self.jc.convert_jarray_to_python(r, j_object)
        else:
            raise Exception('Invalid field definition')

        return ret

    cdef read_static_field(self):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject

        # return type of the java method
        r = self.definition[0]

        # now call the java method
        if r == 'Z':
            j_boolean = self.j_env[0].GetStaticBooleanField(
                    self.j_env, self.j_self, self.j_field)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].GetStaticByteField(
                    self.j_env, self.j_self, self.j_field)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].GetStaticCharField(
                    self.j_env, self.j_self, self.j_field)
            ret = chr(<char>j_char)
        elif r == 'S':
            j_short = self.j_env[0].GetStaticShortField(
                    self.j_env, self.j_self, self.j_field)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].GetStaticIntField(
                    self.j_env, self.j_self, self.j_field)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].GetStaticLongField(
                    self.j_env, self.j_self, self.j_field)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].GetStaticFloatField(
                    self.j_env, self.j_self, self.j_field)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].GetStaticDoubleField(
                    self.j_env, self.j_self, self.j_field)
            ret = <double>j_double
        elif r == 'L':
            j_object = self.j_env[0].GetStaticObjectField(
                    self.j_env, self.j_self, self.j_field)
            if j_object == NULL:
                return None
            if self.definition == 'Ljava/lang/String;':
                c_str = <char *>self.j_env[0].GetStringUTFChars(
                        self.j_env, j_object, NULL)
                py_str = <bytes>c_str
                self.j_env[0].ReleaseStringUTFChars(
                        self.j_env, j_object, c_str)
                ret = py_str
            else:
                ret_jobject = JavaObject()
                ret_jobject.obj = j_object
                ret = ret_jobject
        elif r == '[':
            r = self.definition[1:]
            j_object = self.j_env[0].GetStaticObjectField(
                    self.j_env, self.j_self, self.j_field)
            ret = self.jc.convert_jarray_to_python(r, j_object)
        else:
            raise Exception('Invalid field definition')

        return ret


cdef class JavaMethod(object):
    '''Used to resolve a Java method, and do the call
    '''
    cdef jmethodID j_method
    cdef JavaClass jc
    cdef JNIEnv *j_env
    cdef jclass j_cls
    cdef jobject j_self
    cdef bytes definition
    cdef object is_static
    cdef object definition_return
    cdef object definition_args

    def __cinit__(self, definition, **kwargs):
        self.j_method = NULL
        self.j_env = NULL
        self.j_cls = NULL

    def __init__(self, definition, **kwargs):
        super(JavaMethod, self).__init__()
        self.definition = <bytes>definition
        self.definition_return, self.definition_args = \
                parse_definition(definition)
        self.is_static = kwargs.get('static', False)

    cdef resolve_method(self, JavaClass jc, bytes name):
        # called by JavaClass when we want to resolve the method name
        self.jc = jc
        self.j_env = jc.j_env
        self.j_cls = jc.j_cls
        self.j_self = jc.j_self
        if self.is_static:
            self.j_method = self.j_env[0].GetStaticMethodID(
                    self.j_env, self.j_cls, <char *>name,
                    <char *>self.definition)
        else:
            self.j_method = self.j_env[0].GetMethodID(
                    self.j_env, self.j_cls, <char *>name,
                    <char *>self.definition)

        if self.j_method == NULL:
            raise JavaException('Unable to found the method'
                    ' {0} in {1}'.format(name, jc.__javaclass__))

    def __call__(self, *args):
        # argument array to pass to the method
        cdef jvalue *j_args = NULL
        cdef list d_args = self.definition_args
        if len(args) != len(d_args):
            raise JavaException('Invalid call, number of argument mismatch')

        try:
            # convert python argument if necessary
            if len(args):
                j_args = <jvalue *>malloc(sizeof(jvalue) * len(d_args))
                if j_args == NULL:
                    raise MemoryError('Unable to allocate memory for java args')
                self.jc.populate_args(self.definition_args, j_args, args)

            # do the call
            if self.is_static:
                return self.call_staticmethod(j_args)
            return self.call_method(j_args)

        finally:
            if j_args != NULL:
                free(j_args)

    cdef call_method(self, jvalue *j_args):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject

        # return type of the java method
        r = self.definition_return[0]

        # now call the java method
        if r == 'V':
            self.j_env[0].CallVoidMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
        elif r == 'Z':
            j_boolean = self.j_env[0].CallBooleanMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].CallByteMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].CallCharMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = chr(<char>j_char)
        elif r == 'S':
            j_short = self.j_env[0].CallShortMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].CallIntMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].CallLongMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].CallFloatMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].CallDoubleMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <double>j_double
        elif r == 'L':
            j_object = self.j_env[0].CallObjectMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            if j_object == NULL:
                return None
            if self.definition_return == 'Ljava/lang/String;':
                c_str = <char *>self.j_env[0].GetStringUTFChars(
                        self.j_env, j_object, NULL)
                py_str = <bytes>c_str
                self.j_env[0].ReleaseStringUTFChars(
                        self.j_env, j_object, c_str)
                ret = py_str
            else:
                ret_jobject = JavaObject()
                ret_jobject.obj = j_object
                ret = ret_jobject
        elif r == '[':
            r = self.definition_return[1:]
            j_object = self.j_env[0].CallObjectMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = self.jc.convert_jarray_to_python(r, j_object)
        else:
            raise Exception('Invalid return definition?')

        return ret

    cdef call_staticmethod(self, jvalue *j_args):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject

        # return type of the java method
        r = self.definition_return[0]

        # now call the java method
        if r == 'V':
            self.j_env[0].CallStaticVoidMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
        elif r == 'Z':
            j_boolean = self.j_env[0].CallStaticBooleanMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].CallStaticByteMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].CallStaticCharMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = chr(<char>j_char)
        elif r == 'S':
            j_short = self.j_env[0].CallStaticShortMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].CallStaticIntMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].CallStaticLongMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].CallStaticFloatMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].CallStaticDoubleMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <double>j_double
        elif r == 'L':
            # accept only string for the moment
            j_object = self.j_env[0].CallStaticObjectMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            if self.definition_return == 'Ljava/lang/String;':
                c_str = <char *>self.j_env[0].GetStringUTFChars(
                        self.j_env, j_object, NULL)
                py_str = <bytes>c_str
                self.j_env[0].ReleaseStringUTFChars(
                        self.j_env, j_object, c_str)
                ret = py_str
            else:
                ret_jobject = JavaObject()
                ret_jobject.obj = j_object
                ret = ret_jobject
        elif r == '[':
            r = self.definition_return[1:]
            j_object = self.j_env[0].CallStaticObjectMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = self.jc.convert_jarray_to_python(r, j_object)
        else:
            raise Exception('Invalid return definition?')

        return ret

class JavaStaticMethod(JavaMethod):
    def __init__(self, definition, **kwargs):
        kwargs['static'] = True
        super(JavaStaticMethod, self).__init__(definition, **kwargs)

class JavaStaticField(JavaField):
    def __init__(self, definition, **kwargs):
        kwargs['static'] = True
        super(JavaStaticField, self).__init__(definition, **kwargs)
