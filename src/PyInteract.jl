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

@pydef mutable struct IJuliaPySession <: pysession.Session
    function send(self, stream, msg_or_type, _content=nothing, _parent=nothing, _ident=nothing, _buffers=nothing, _track=false, _header=nothing, _metadata=nothing; content=_content, parent=_parent, ident=_ident, buffers=_buffers, track=_track, header=_header, metadata=_metadata)
        IJulia.send_ipython(stream,
            IJulia.Msg(ident === nothing ? String[] : [string(ident)],
                header === nothing ? IJulia.msg_header(IJulia.execute_msg, msg_or_type) : header,
                content === nothing ? Dict() : content,
                parent === nothing ? Dict() : pysession.extract_header(parent),
                metadata === nothing ? Dict() : metadata))
    end
end

pymsg(msg) = Dict("content" => msg.content,
                  "header" => msg.header,
                  "parent_header" => msg.parent_header,
                  "metadata" => msg.metadata)

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

    function register_target(self, target, f)
        @warn "Zounds! unsupported register_target call."
    end
end

@pydef mutable struct IJuliaPyKernel <: pykernelbase.Kernel
    function __init__(self)
        self.session = IJuliaPySession()
        self.comm_manager = IJuliaPyCommManager(self)

        # Some things expect shell to be defined.
        self.shell = nothing
    end

    iopub_socket.get(self) = IJulia.publish[]
    _parent_header.get(self) = IJulia.execute_msg.header
end

const WIDGET_MIME = MIME"application/vnd.jupyter.widget-view+json"
Base.show(io::IO, ::WIDGET_MIME, x::PyObject) =
    JSON.print(io, Dict("version_major"=>2, "version_minor"=>0, "model_id"=>x._model_id))
Base.istextmime(::WIDGET_MIME) = true
push!(IJulia.ijulia_jsonmime_types, WIDGET_MIME())

if IJulia.inited
    IJuliaPyKernel.instance()
end

end # module
