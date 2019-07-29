__precompile__(false)

"""
`PyInteract` is a Julia module that combines PyCall and IJulia to support
IPython-based interactive widgets in IJulia notebooks.

For example, in an IJulia notebook, you can do:
```
using PyCall, PyInteract

ipywidgets = pyimport("ipywidgets")
widget = ipywidgets.IntSlider(5)
```
"""
module PyInteract

using PyCall
import IJulia, JSON

const pycomm = pyimport("ipykernel.comm")
const pykernelbase = pyimport("ipykernel.kernelbase")
const pysession = pyimport("jupyter_client.session")
const IPython = pyimport("IPython")

"""
A shim around Jupyter's Session class.

The Session class is responsible for sending a message over the Jupyter
transport (usually several ZMQ sockets). We simply override the send method to
call IJulia's `send_ipython` method.
"""
@pydef mutable struct IJuliaPySession <: pysession.Session
    # NOTE: We have to do this ugliness because the IPython/Jupyter codebase
    # make heavy use of both positional and keyword arguments.
    function send(
            self, stream, msg_or_type,
            _content=nothing, _parent=nothing, _ident=nothing,
            _buffers=nothing, _track=false, _header=nothing,
            _metadata=nothing;
            content=_content, parent=_parent, ident=_ident,
            buffers=_buffers, track=_track, header=_header,
            metadata=_metadata,
    )
        IJulia.send_ipython(
            stream,
            IJulia.Msg(
                ident === nothing ? String[] : [string(ident)],
                header === nothing ? IJulia.msg_header(IJulia.execute_msg, msg_or_type) : header,
                content === nothing ? Dict() : content,
                parent === nothing ? Dict() : pysession.extract_header(parent),
                metadata === nothing ? Dict() : metadata,
            ),
        )
    end
end

pymsg(msg) = Dict("content" => msg.content,
                  "header" => msg.header,
                  "parent_header" => msg.parent_header,
                  "metadata" => msg.metadata)

"""
A shim around IPyKernel's CommManager class.

The CommManager is responsible for managing the lifecycle of Jupyter comms.

## Background & Terminology
Comms can be opened from the frontend (usually a Jupyter notebook) to the kernel
or from the kernel to the frontend (which side opens the comm depends on the
specific application/library - in the case of ipywidgets, comms are opened from
the kernel to the frontend).

A comm target can be thought of as a class whereas an individual comm can be
thought of as an instance of that class. For example, in ipywidgets, there is an
ipywidgets comm target, and every widget has an individual comm which are
instances of the ipywidget comm target.

There are two important methods:
    * `register_comm` - This method is called by individual comms to inform the
        CommManager of their existence. This allows the CommManager to forward
        incoming IOPub messages to the right comm instance.
    * `register_target` - This method is called by libraries to tell the
        CommManager about a new comm target. This allows the kernel to create
        new comm instances when the frontend opens a comm to the kernel.
"""
@pydef mutable struct IJuliaPyCommManager <: pycomm.CommManager
    function __init__(self, kernel)
        self.kernel = kernel
    end

    function register_comm(self, comm)
        comm.kernel = self.kernel
        jlcomm = IJulia.CommManager.Comm(
            :python, comm.comm_id, false,
            msg -> comm.handle_msg(pymsg(msg)),
            msg -> comm.handle_close(pymsg(msg)),
        )
        PyDict(self."comms")[jlcomm.id] = comm
        IJulia.CommManager.comms[jlcomm.id] = jlcomm
    end

    # For right now, we don't support registering comm targets because we're
    # just trying to get ipywidgets to work (which only opens comms from the
    # kernel to the frontend). This could be implemented in the future.
    function register_target(self, target, f)
        @warn "Zounds! unsupported IJuliaPyCommManager.register_target call."
    end
end

"""
A shim around IPyKernel's Kernel class.

Many parts of the IPython codebase attempt to access the kernel instance (it's
a global singleton) so we need to shim it in order to redirect things to the
correct places in IJulia (e.g. we redirect the IOPub socket to IJulia's).
"""
@pydef mutable struct IJuliaPyKernel <: pykernelbase.Kernel
    function __init__(self)
        self.session = IJuliaPySession()
        self.comm_manager = IJuliaPyCommManager(self)

        # Some things expect shell to be defined.
        # TODO: we actually need to shim shell to get IPython's display(...)
        # method to work correctly.
        self.shell = nothing
    end

    iopub_socket.get(self) = IJulia.publish[]
    _parent_header.get(self) = IJulia.execute_msg.header
end

# TODO: We should be able to delete this (or at least make this not
# ipywidgets-specific) once we can hook into IPython's display system.
const WIDGET_MIME = MIME"application/vnd.jupyter.widget-view+json"
function Base.show(io::IO, ::WIDGET_MIME, x::PyObject)
    JSON.print(
        io,
        Dict(
            "version_major" => 2,
            "version_minor" => 0,
            "model_id" => x._model_id,
        ),
    )
end
Base.istextmime(::WIDGET_MIME) = true
push!(IJulia.ijulia_jsonmime_types, WIDGET_MIME())

if IJulia.inited
    IJuliaPyKernel.instance()
end

end # module
