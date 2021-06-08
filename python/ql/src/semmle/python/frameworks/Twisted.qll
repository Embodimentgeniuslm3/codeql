/**
 * Provides classes modeling security-relevant aspects of the `twisted` PyPI package.
 * See https://twistedmatrix.com/.
 */

private import python
private import semmle.python.dataflow.new.DataFlow
private import semmle.python.dataflow.new.RemoteFlowSources
private import semmle.python.dataflow.new.TaintTracking
private import semmle.python.Concepts
private import semmle.python.ApiGraphs

/**
 * Provides models for the `twisted` PyPI package.
 * See https://twistedmatrix.com/.
 */
private module Twisted {
  // ---------------------------------------------------------------------------
  // request handler modeling
  // ---------------------------------------------------------------------------
  /**
   * A class that is a subclass of `twisted.web.resource.Resource`, thereby
   * being able to handle HTTP requests.
   *
   * See https://twistedmatrix.com/documents/21.2.0/api/twisted.web.resource.Resource.html
   */
  class TwistedResourceSubclass extends Class {
    TwistedResourceSubclass() {
      this.getABase() =
        API::moduleImport("twisted")
            .getMember("web")
            .getMember("resource")
            .getMember("Resource")
            .getASubclass*()
            .getAUse()
            .asExpr()
    }

    /** Gets a function that could handle incoming requests, if any. */
    Function getARequestHandler() {
      // TODO: This doesn't handle attribute assignment. Should be OK, but analysis is not as complete as with
      // points-to and `.lookup`, which would handle `post = my_post_handler` inside class def
      result = this.getAMethod() and
      resourceMethodRequestParamIndex(result.getName(), _)
    }
  }

  /**
   * Holds if the request parameter is supposed to be at index `requestParamIndex` for
   * the method named `methodName` in `twisted.web.resource.Resource`.
   */
  bindingset[methodName]
  private predicate resourceMethodRequestParamIndex(string methodName, int requestParamIndex) {
    methodName.matches("render_%") and requestParamIndex = 1
    or
    methodName in ["render", "listDynamicEntities", "getChildForRequest"] and requestParamIndex = 1
    or
    methodName = ["getDynamicEntity", "getChild", "getChildWithDefault"] and requestParamIndex = 2
  }

  /** A method that handles incoming requests, on a `twisted.web.resource.Resource` subclass. */
  class TwistedResourceRequestHandler extends HTTP::Server::RequestHandler::Range {
    TwistedResourceRequestHandler() {
      any(TwistedResourceSubclass cls).getAMethod() = this and
      resourceMethodRequestParamIndex(this.getName(), _)
    }

    Parameter getRequestParameter() {
      exists(int i |
        resourceMethodRequestParamIndex(this.getName(), i) and
        result = this.getArg(i)
      )
    }

    override Parameter getARoutedParameter() { none() }

    override string getFramework() { result = "twisted" }
  }

  /**
   * A "render" method on a `twisted.web.resource.Resource` subclass, whose return value
   * is written as the body fo the HTTP response.
   */
  class TwistedResourceRenderMethod extends TwistedResourceRequestHandler {
    TwistedResourceRenderMethod() {
      this.getName() = "render" or this.getName().matches("render_%")
    }
  }

  // ---------------------------------------------------------------------------
  // request modeling
  // ---------------------------------------------------------------------------
  /**
   * Provides models for the `twisted.web.server.Request` class
   *
   * See https://twistedmatrix.com/documents/21.2.0/api/twisted.web.server.Request.html
   */
  module Request {
    /**
     * A source of instances of `twisted.web.server.Request`, extend this class to model new instances.
     *
     * This can include instantiations of the class, return values from function
     * calls, or a special parameter that will be set when functions are called by an external
     * library.
     *
     * Use `Request::instance()` predicate to get
     * references to instances of `twisted.web.server.Request`.
     */
    abstract class InstanceSource extends DataFlow::LocalSourceNode { }

    /** Gets a reference to an instance of `twisted.web.server.Request`. */
    private DataFlow::LocalSourceNode instance(DataFlow::TypeTracker t) {
      t.start() and
      result instanceof InstanceSource
      or
      exists(DataFlow::TypeTracker t2 | result = instance(t2).track(t2, t))
    }

    /** Gets a reference to an instance of `twisted.web.server.Request`. */
    DataFlow::Node instance() { instance(DataFlow::TypeTracker::end()).flowsTo(result) }
  }

  /**
   * A parameter that will receive a `twisted.web.server.Request` instance,
   * when a twisted request handler is called.
   */
  class TwistedResourceRequestHandlerRequestParam extends RemoteFlowSource::Range,
    Request::InstanceSource, DataFlow::ParameterNode {
    TwistedResourceRequestHandlerRequestParam() {
      this.getParameter() = any(TwistedResourceRequestHandler handler).getRequestParameter()
    }

    override string getSourceType() { result = "twisted.web.server.Request" }
  }

  /**
   * Taint propagation for `twisted.web.server.Request`.
   */
  private class TwistedRequestAdditionalTaintStep extends TaintTracking::AdditionalTaintStep {
    override predicate step(DataFlow::Node nodeFrom, DataFlow::Node nodeTo) {
      // Methods
      //
      // TODO: When we have tools that make it easy, model these properly to handle
      // `meth = obj.meth; meth()`. Until then, we'll use this more syntactic approach
      // (since it allows us to at least capture the most common cases).
      nodeFrom = Request::instance() and
      exists(DataFlow::AttrRead attr | attr.getObject() = nodeFrom |
        // normal (non-async) methods
        attr.getAttributeName() in [
            "getCookie", "getHeader", "getAllHeaders", "getUser", "getPassword", "getHost",
            "getRequestHostname"
          ] and
        nodeTo.(DataFlow::CallCfgNode).getFunction() = attr
      )
      or
      // Attributes
      nodeFrom = Request::instance() and
      nodeTo.(DataFlow::AttrRead).getObject() = nodeFrom and
      nodeTo.(DataFlow::AttrRead).getAttributeName() in [
          "uri", "path", "prepath", "postpath", "content", "args", "received_cookies",
          "requestHeaders", "user", "password", "host"
        ]
    }
  }

  /**
   * A parameter of a request handler method (on a `twisted.web.resource.Resource` subclass)
   * that is also given remote user input. (a bit like RoutedParameter).
   */
  class TwistedResourceRequestHandlerExtraSources extends RemoteFlowSource::Range,
    DataFlow::ParameterNode {
    TwistedResourceRequestHandlerExtraSources() {
      exists(TwistedResourceRequestHandler func, int i |
        func.getName() in ["getChild", "getChildWithDefault"] and i = 1
        or
        func.getName() = "getDynamicEntity" and i = 1
      |
        this.getParameter() = func.getArg(i)
      )
    }

    override string getSourceType() { result = "twisted Resource method extra parameter" }
  }

  // ---------------------------------------------------------------------------
  // response modeling
  // ---------------------------------------------------------------------------
  /**
   * Implicit response from returns of render methods.
   */
  private class TwistedResourceRenderMethodReturn extends HTTP::Server::HttpResponse::Range,
    DataFlow::CfgNode {
    TwistedResourceRenderMethodReturn() {
      this.asCfgNode() = any(TwistedResourceRenderMethod meth).getAReturnValueFlowNode()
    }

    override DataFlow::Node getBody() { result = this }

    override DataFlow::Node getMimetypeOrContentTypeArg() { none() }

    override string getMimetypeDefault() { result = "text/html" }
  }

  /**
   * A call to the `twisted.web.server.Request.write` function.
   *
   * See https://twistedmatrix.com/documents/21.2.0/api/twisted.web.server.Request.html#write
   */
  class TwistedRequestWriteCall extends HTTP::Server::HttpResponse::Range, DataFlow::CallCfgNode {
    TwistedRequestWriteCall() {
      // TODO: When we have tools that make it easy, model these properly to handle
      // `meth = obj.meth; meth()`. Until then, we'll use this more syntactic approach
      // (since it allows us to at least capture the most common cases).
      exists(DataFlow::AttrRead read |
        this.getFunction() = read and
        read.getObject() = Request::instance() and
        read.getAttributeName() = "write"
      )
    }

    override DataFlow::Node getBody() {
      result.asCfgNode() in [node.getArg(0), node.getArgByName("data")]
    }

    override DataFlow::Node getMimetypeOrContentTypeArg() { none() }

    override string getMimetypeDefault() { result = "text/html" }
  }

  /**
   * A call to the `redirect` function on a twisted request.
   *
   * See https://twistedmatrix.com/documents/21.2.0/api/twisted.web.http.Request.html#redirect
   */
  class TwistedRequestRedirectCall extends HTTP::Server::HttpRedirectResponse::Range,
    DataFlow::CallCfgNode {
    TwistedRequestRedirectCall() {
      // TODO: When we have tools that make it easy, model these properly to handle
      // `meth = obj.meth; meth()`. Until then, we'll use this more syntactic approach
      // (since it allows us to at least capture the most common cases).
      exists(DataFlow::AttrRead read |
        this.getFunction() = read and
        read.getObject() = Request::instance() and
        read.getAttributeName() = "redirect"
      )
    }

    override DataFlow::Node getBody() { none() }

    override DataFlow::Node getRedirectLocation() {
      result.asCfgNode() in [node.getArg(0), node.getArgByName("url")]
    }

    override DataFlow::Node getMimetypeOrContentTypeArg() { none() }

    override string getMimetypeDefault() { result = "text/html" }
  }
}
