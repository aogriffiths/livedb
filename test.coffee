# Nodeunit test
mongoskin = require 'mongoskin'
redisLib = require 'redis'
alive = require './lib'

id = 0

createClient = ->
  mongo = require('mongoskin').db 'localhost:27017/test?auto_reconnect', safe:false
  mongowrapper = alive.mongo(mongo)

  redis = redisLib.createClient()
  redis.select 15

  client = alive.client mongowrapper, redis
  {client, redis, mongo, mongowrapper}

module.exports =
  setUp: (callback) ->
    {@client, @redis, @mongo, @mongowrapper} = createClient()

    # Clear the databases
    @mongo.dropCollection '_test'
    @redis.flushdb()

    @collection = @client.collection (@cName = '_test')
    @doc = "id#{id++}"
    @create = (cb) ->
      op = op:'set', p:[], val:{}
      @collection.submit @doc, v:0, op:op, (err, v) ->
        throw new Error err if err
        cb?()
    callback()

  tearDown: (callback) ->
    @mongowrapper.close()
    @redis.quit()
    callback()
    
  'submit a create op': (test) ->
    op = op:'set', p:[], val:'hi'
    @collection.submit @doc, v:0, op:op, (err, v) ->
      throw new Error err if err
      test.strictEqual v, 0
      test.done()

  'created documents can be fetched': (test) -> @create =>
    @collection.fetch @doc, (err, {v, data}) ->
      throw new Error err if err
      test.deepEqual data, {}
      test.strictEqual v, 1
      test.done()

  'modify a document': (test) -> @create =>
    op = op:'set', p:['a'], val:'hi'
    @collection.submit @doc, v:1, op:op, (err, v) =>
      throw new Error err if err
      @collection.fetch @doc, (err, {v, data}) =>
        throw new Error err if err
        test.deepEqual data, {a:'hi'}
        test.done()

  'remove a doc': (test) -> @create =>
    op = op:'rm', p:[]
    @collection.submit @doc, v:1, op:op, (err, v) =>
      throw new Error err if err
      @collection.fetch @doc, (err, {v, data}) =>
        throw new Error err if err
        test.equal data, null
        test.done()

  'Repeated operations are not executed': (test) -> @create =>
    op = op:'set', p:[], val:{arr:[]}
    @collection.submit @doc, v:1, op:op, (err, v) =>
      throw new Error err if err
      op = op:'ins', p:['arr', 0], val:'x'
      @collection.submit @doc, v:2, id:'abc.123', op:op, (err, v) =>
        throw new Error err if err
        @collection.submit @doc, v:2, id:'abc.123', op:op, (err, v) =>
          test.strictEqual err, 'Op already submitted'
          test.done()
 
  'Observe':
    'local changes': (test) -> @create =>
      @collection.observe @doc, 1, (err, stream) =>
        throw new Error err if err

        op = op:'set', p:['a'], val:'hi'
        stream.on 'readable', ->
          test.deepEqual stream.read(), {v:1, op:op, id:'abc.123'}
          stream.destroy()
          test.done()

        @collection.submit @doc, v:1, op:op, id:'abc.123'

    'From an old version': (test) -> @create =>
      # The document has version 1
      @collection.observe @doc, 0, (err, stream) =>
        stream.once 'readable', =>
          test.deepEqual stream.read(), {v:0, op:{op:'set', p:[], val:{}}}

          # And we still get ops that come in now.
          op = op:'set', p:['a'], val:'hi'
          @collection.submit @doc, v:1, op:op, id:'abc.123'
          stream.once 'readable', ->
            test.deepEqual stream.read(), {v:1, op:op, id:'abc.123'}
            stream.destroy()
            test.done()

    'document that doesnt exist yet': (test) ->
      @collection.observe @doc, 0, (err, stream) =>
        stream.on 'readable', ->
          test.deepEqual stream.read(), {v:0, op:{op:'set', p:[], val:{}}}
          stream.destroy()
          test.done()

        @create()

    'double stream.destroy throws': (test) ->
      @collection.observe @doc, 1, (err, stream) =>
        stream.destroy()
        test.throws -> stream.destroy()
        test.done()
    
    'separate clients 1': (test) -> @create =>
      numClients = 50
      clients = (createClient() for [0...numClients])

      for c, i in clients
        c.client.submit @cName, @doc, v:1, op:{op:'ins', p:['x', -1], val:i}

      @collection.observe @doc, 1, (err, stream) =>
        # We should get numClients ops on the stream, in order.
        seq = 1
        stream.on 'readable', tryRead = =>
          data = stream.read()
          return unless data
          #console.log 'read', data
          delete data.op.val
          test.deepEqual data, {v:seq, op:{op:'ins', p:['x', -1]}}

          if seq is numClients
            #console.log 'destroy stream'
            stream.destroy()

            for c, i in clients
              c.redis.quit()
              c.mongowrapper.close()
            test.done()

            # Uncomment to see the actually submitted data
            #@collection.fetch @doc, (err, {v, data}) =>
            #  console.log data
          else
            seq++

          tryRead()
