
mqtt = null

io = null # this will be defined in the start method

module.exports = (app) ->
  Data = app.models.Data

  publish_payload = (topic, payload) ->
    Data.findOrCreate topic, payload

  app.get /^\/topics\/(.+)$/, (req, res) ->
    topic = req.params[0]

    topics = req.session.topics || []
    index = topics.indexOf(topic)
    console.log index
    if index >= 0
      topics = [].concat(topics.splice(0, index), topics.splice(index + 1, req.session.topics.length))
    topics.push(topic)
    topics.pull() if topics.length > 5
    req.session.topics = topics

    Data.find topic, (data, err) ->
      if req.accepts 'json'
        res.contentType('json')
        try
          # if it's a json, we parse it and render
          value = JSON.parse(data.getValue())
        catch e
          # else we transform it in string
          value = "" + data.getValue()
        if err?
          res.json null, 404
        else
          res.json value
      else
        res.render 'topic.hbs', topic: req.params.topic

  app.put /^\/topics\/(.+)$/, (req, res) ->
    topic = req.params[0]
    publish_payload(topic, req.body.payload)
    res.send 204

  # setup websockets
  io = require('socket.io').listen(app)

  io.configure 'production', ->
    io.enable('browser client minification');  # send minified client
    io.enable('browser client etag');          # apply etag caching logic based on version number
    io.enable('browser client gzip');          # gzip the file
    io.set('log level', 1)

    io.set('transports', [
      'htmlfile'
    , 'xhr-polling'
    , 'jsonp-polling'
    ])

  io.configure 'development', ->
    io.set('transports', ['websocket'])

  io.sockets.on 'connection', (socket) ->

    subscriptions = {}

    socket.on 'subscribe', (topic) ->

      Data.findOrCreate topic, (data) ->

        subscription = (currentData) ->
          socket.emit("/topics/#{topic}", currentData.getValue())

        subscriptions[topic] = subscription

        data.on('change', subscription)

        subscription(data) if data.getValue()

    socket.on 'disconnect', ->

      for topic, listener of subscriptions
        Data.findOrCreate topic, (data) ->
          data.removeListener('change', listener)

  mqtt = app.mqtt.createServer (client) ->

    listeners = {}
    globalListener = null

    unsubscribe_all = ->
      Data.removeListener('newData', globalListener) if globalListener?
      for topic, listener of listeners
        Data.find topic, (data) ->
          data.removeListener('change', listener)

    client.on 'connect', (packet) ->
      client.id = packet.client
      console.log "Connected MQTT client #{client.id}"
      client.connack(returnCode: 0)

    client.on 'subscribe', (packet) ->
      granted = []
      subscriptions = []

      for subscription in packet.subscriptions
        # '#' is 'match anything to the end of the string' */
        # + is 'match anything but a / until you hit a /' */
        reg = new RegExp(subscription.topic.replace('+', '[^\/]+').replace('#', '.+$'));
        subscriptions.push(reg)
        granted.push 0

      client.suback(messageId: packet.messageId, granted: granted)

      addListener = (data) ->

        listener = (currentData) ->
          try
            client.publish(topic: currentData.getKey(), payload: currentData.getValue())
          catch error
            console.log error
            unsubscribe_all()

        data.on 'change', listener

        listeners[data.getKey()] = listener

        listener(data) if data.getValue()?

      # push the latest value to the new client,
      # do not wait updates of the topic
      for subscription in subscriptions
        Data.find subscription, addListener

      globalListener = (data) ->
        for subscription in subscriptions
          addListener(data) if subscription.test(data.getKey())

      Data.on 'newData', globalListener

    client.on 'publish', (packet) ->
      publish_payload packet.topic, packet.payload

    client.on 'pingreq', (packet) ->
	    client.pingresp()

    client.on 'disconnect', ->
      client.stream.end()

    client.on 'error', (error) ->
      console.log error
      client.stream.end()

   	client.on 'close', (err) ->
      unsubscribe_all()
    
    client.on 'unsubscribe', (packet) ->
      # we do a trick to save our bench
      unsubscribe_all()
      client.unsuback(messageId: packet.messageId)

  return { 
    start: (port) ->
      mqtt.listen(port)
  }
