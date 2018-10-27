part of nyxx.commands;

/// Main point of commands in nyx.
/// It gets all sent messages and matches to registered command and invokes its action.
class CommandsFramework {
  List<_CommandMetadata> _commands;

  List<TypeConverter> _typeConverters;
  CooldownCache _cooldownCache;
  List<Object> _services = List();

  StreamController<CommandExecutionError> _onError;
  Stream<CommandExecutionError> onError;

  List<Snowflake> _admins;
  final Logger _logger = Logger("CommandsFramework");

  /// Prefix needed to dispatch a commands.
  /// All messages without this prefix will be ignored
  String prefix;

  /// Creates commands framework handler. Requires prefix to handle commands.
  CommandsFramework(this.prefix,
      {Duration roundupTime = const Duration(minutes: 2), bool ignoreBots = true, List<Snowflake> admins}) {
    this._commands = List();
    _cooldownCache = CooldownCache(roundupTime);
    _admins = admins;

    _onError = StreamController.broadcast();
    onError = _onError.stream;

    client.onMessageReceived.listen((MessageReceivedEvent e) {
      if (ignoreBots && e.message.author.bot) return;
      if (!e.message.content.startsWith(prefix)) return;

      Future(() => _dispatch(e));
    });
  }

  /// Allows to register new converters for custom type
  void registerTypeConverters(List<TypeConverter> converters) =>
      _typeConverters.addAll(converters);

  /// Register services to injected into commands modules. Has to be executed before registering commands.
  /// There cannot be more than 1 dependency with single type. Only first will be injected.
  void registerServices(List<Object> services) =>
      this._services.addAll(services);

  /// Register all services in current isolate. It captures all classes which inherits from [Service] class and performs dependency injection if possible.
  void discoverServices() {
    var superClass = reflectClass(Service);
    var mirrorSystem = currentMirrorSystem();

    mirrorSystem.libraries.forEach((uri, lib) {
      for (var cm in lib.declarations.values) {
        if (cm is ClassMirror) {
          if (cm.isSubclassOf(superClass) && !cm.isAbstract) {
            var toInject = _createConstuctorInjections(cm);

            try {
              var serv = cm.newInstance(Symbol(''), toInject).reflectee;
              _services.add(serv);
            } catch (e) {
              throw Exception(
                  "Service [${util.getSymbolName(cm.simpleName)}] constructor not satisfied!");
            }

            break;
          }
        }
      }
    });
  }

  List<Object> _createConstuctorInjections(ClassMirror service) {
    var ctor = service.declarations.values.toList().firstWhere((m) {
      if (m is MethodMirror) return m.isConstructor;

      return false;
    }) as MethodMirror;

    var params = ctor.parameters;
    var toInject = List<dynamic>();

    for (var param in params) {
      for (var service in _services) {
        if (param.type.reflectedType == service.runtimeType ||
            param.type.isAssignableTo(reflectType(service.runtimeType)))
          toInject.add(service);
      }
    }
    return toInject;
  }

  String _createLog(Module classCmd, Command methodCmd) {
    if(classCmd == null)
      return "[${methodCmd.name}]";

    if(methodCmd == null)
      return "[${methodCmd.name}]";

    return "[${classCmd.name} ${methodCmd.name != null ? methodCmd.name : "<MAIN>"}]";
  }

  List<List> _getProcessors(
      ClassMirror classMirror, DeclarationMirror methodMirror) {
    var classPre = List<Preprocessor>();
    var classPost = List<Postprocessor>();

    if (classMirror != null) {
      classPre.addAll(util.getCmdAnnots<Preprocessor>(classMirror));
      classPost.addAll(util.getCmdAnnots<Postprocessor>(classMirror));
    }

    var methodPre = util.getCmdAnnots<Preprocessor>(methodMirror);
    var methodPost = util.getCmdAnnots<Postprocessor>(methodMirror);

    var prepro = List<Preprocessor>.from(classPre)
      ..addAll(methodPre);
    var postPro = List<Postprocessor>.from(classPost)
      ..addAll(methodPost);

    return [prepro, postPro];
  }

  /// Register commands in current Isolate's libraries. Basically loads all classes as commands with [CommandContext] superclass.
  /// Performs dependency injection when instantiate commands. And throws [Exception] when there are missing services
  void discoverCommands() {
    var mirrorSystem = currentMirrorSystem();

    mirrorSystem.libraries.forEach((_, library) {
     for(var declaration in library.declarations.values) {
       var commandAnnot = util.getCmdAnnot<Module>(declaration);

       if(commandAnnot == null)
         continue;

       if(declaration is MethodMirror) {
         var cmdAnnot = commandAnnot as Command;
         var methodRestrict = util.getCmdAnnot<Restrict>(declaration);
         var processors = _getProcessors(null, declaration);

         var meta = _CommandMetadata([[commandAnnot.name]..addAll(commandAnnot.aliases)], declaration, library, null, cmdAnnot, _patchRestrictions(null, methodRestrict),
             processors.first as List<Preprocessor>, processors.last as List<Postprocessor>);

         _commands.add(meta);
       } else if (declaration is ClassMirror) {
         var classRestrict = util.getCmdAnnot<Restrict>(declaration);

         for(var method in declaration.declarations.values.whereType<MethodMirror>()) {
           var methodCmd = util.getCmdAnnot<Command>(method);

           if(methodCmd == null)
             continue;

           var methodRestrict = util.getCmdAnnot<Restrict>(declaration);
           var processors = _getProcessors(declaration, method);

           List<List<String>> name = List();
           name.add(List.of(commandAnnot.aliases)..add(commandAnnot.name));

           if(methodCmd.name != null) {
             name.add(List.from(methodCmd.aliases)..add(methodCmd.name));
           }

           var meta = _CommandMetadata(name, method, declaration, commandAnnot, methodCmd,
               _patchRestrictions(classRestrict, methodRestrict), processors.first as List<Preprocessor>, processors.last as List<Postprocessor>);

           _commands.add(meta);
         }
       }
     }
    });
    _logger.fine("Registered ${_commands.length} commands");
    _commands.sort((first, second) => -first.commandString.length.compareTo(second.commandString.length));
  }

  Restrict _patchRestrictions(Restrict top, Restrict meth) {
    if (top == null && meth == null)
      return Restrict();
    else if (top == null)
      return meth;
    else if (meth == null)
      return top;

    var admin = meth.admin ?? top.admin;

    List<Snowflake> roles = List.from(top.roles)..addAll(meth.roles);

    List<int> userPermissions = List.from(top.userPermissions)
      ..addAll(meth.userPermissions);
    List<int> botPermissions = List.from(top.botPermissions)
      ..addAll(meth.botPermissions);
    List<String> topics = List.from(top.topics)..addAll(meth.topics);

    var cooldown = meth.cooldown ?? top.cooldown;
    var context = meth.requiredContext ?? top.requiredContext;
    var nsfw =  meth.nsfw ?? top.nsfw;

    return Restrict(
        admin: admin,
        roles: roles,
        userPermissions: userPermissions,
        botPermissions: botPermissions,
        cooldown: cooldown,
        requiredContext: context,
        nsfw: nsfw,
        topics: topics);
  }

  /// Dispatches onMessage event to framework.
  Future _dispatch(MessageReceivedEvent e) async {
    var s = Stopwatch()..start();

    var splittedCommand = _escapeParameters(
        e.message.content.replaceFirst(prefix, "").trim().split(' '));

    bool single = true;
    _CommandMetadata matchedMeta;
    try {
      matchedMeta = _commands.firstWhere((command) {
        if(command.commandString.length == 2 && splittedCommand.length > 1) {
          if(command.commandString.first.contains(splittedCommand.first) && command.commandString.last.contains(splittedCommand[1])) {
            single = false;
            return true;
          }

          return false;
        } else {
          if(command.parent is ClassMirror && command.methodCommand.name != null)
            return false;

          if(command.commandString.first.contains(splittedCommand.first)) return true;
          return false;
        }
      });
    } on Error {
      _onError.add(CommandExecutionError(ExecutionErrorType.commandNotFound, e.message));
      return;
    }


    var executionCode = -1;
    executionCode = await checkPermissions(matchedMeta, e.message);

    if(executionCode == -1 && matchedMeta.preprocessors.length > 0) {
      for(var p in matchedMeta.preprocessors) {
        try {
          var res = await p.execute(_services, e.message);

          if(!res.isSuccessful) {
            _onError.add(CommandExecutionError(ExecutionErrorType.preprocessorFail, e.message, res.exception, res.message));
            executionCode = 8;
            break;
          }
        } catch (err) {
          _onError.add(CommandExecutionError(ExecutionErrorType.preprocessorException, e.message, err as Exception));
        }
      }
    }

    /// Submethod to invoke postprocessors
    void invokePost(res) {
      if (matchedMeta.postprocessors.length > 0) {
        for (var post in matchedMeta.postprocessors)
          post.execute(
              _services,
              res,
              e.message);
      }
    }

    // Switch between execution codes
    switch (executionCode) {
      case 0:
        _onError.add(CommandExecutionError(ExecutionErrorType.adminOnly, e.message));
        break;
      case 1:
        _onError.add(CommandExecutionError(ExecutionErrorType.userPermissionsError, e.message));
        break;
      case 6:
        _onError.add(CommandExecutionError(ExecutionErrorType.botPermissionError, e.message));
        break;
      case 2:
        _onError.add(CommandExecutionError(ExecutionErrorType.cooldown, e.message));
        break;
      case 3:
        _onError.add(CommandExecutionError(ExecutionErrorType.wrongContext, e.message));
        break;
      case 4:
        _onError.add(CommandExecutionError(ExecutionErrorType.nfswAccess, e.message));
        break;
      case 5:
        _onError.add(CommandExecutionError(ExecutionErrorType.requiredTopic, e.message));
        break;
      case 7:
        _onError.add(CommandExecutionError(ExecutionErrorType.roleRequired, e.message));
        break;
      case 8: break;
      case -1:
      case -2:
      case 100:
        if(single)
          splittedCommand.removeRange(0, 1);
        else
          splittedCommand.removeRange(0, 2);

        var methodInj = await _injectParameters(
            matchedMeta.method, splittedCommand, e.message);

        if (matchedMeta.parent is ClassMirror) {
          var cm = matchedMeta.parent as ClassMirror;
          var toInject = _createConstuctorInjections(cm);

          var instance = cm.newInstance(Symbol(''), toInject);

          instance.setField(Symbol("guild"), e.message.guild);
          instance.setField(Symbol("message"), e.message);
          instance.setField(Symbol("author"), e.message.author);
          instance.setField(Symbol("channel"), e.message.channel);

          (instance.invoke(matchedMeta.method.simpleName, methodInj)
              .reflectee as Future).then((r) {
            invokePost(r);
          }).catchError((Exception err, String stack) {
            invokePost([err, stack]);
            _onError.add(CommandExecutionError(ExecutionErrorType.commandFailed, e.message, err, stack));
          });
        }

        if (matchedMeta.parent is LibraryMirror) {
          var context = CommandContext._new(e.message.channel,
              e.message.author, e.message.guild, e.message);

          (matchedMeta.parent.invoke(
                matchedMeta.method.simpleName,
                List()
                  ..add(context)
                  ..addAll(methodInj)).reflectee as Future).then((r) {
            invokePost(r);
          }).catchError((Exception err, String stack) {
            invokePost([err, stack]);
            _onError.add(CommandExecutionError(ExecutionErrorType.commandFailed, e.message, err, stack));
          });
        }

        _logger.info(
            "Command ${_createLog(matchedMeta.parentCommand, matchedMeta.methodCommand)} executed");

        print(s.elapsedMicroseconds);
        break;
    }
  }

  Future<int> checkPermissions(_CommandMetadata meta, Message e) async {
    int executionCode = -1;
    var annot = meta.restrict;
    
    // Check if command requires admin
    if (executionCode == -1 && annot.admin != null && annot.admin)
      return _isUserAdmin(e.author.id, e.guild) ? 100 : 0;

    // Check for reqired context
    if(annot.requiredContext != null) {
      if(annot.requiredContext == ContextType.Dm && !(e.channel is DMChannel || e.channel is GroupDMChannel))
        return 3;

      if(annot.requiredContext == ContextType.Guild && e.channel is! TextChannel)
        return 3;
    }

    if(e.guild != null) {
      var member = await e.guild.getMember(e.author);

      // Check if there is need to check user roles
      if (executionCode == -1 && annot.roles.isNotEmpty) {
        var hasRoles =
        member.roles.map((f) => f.id).any((t) => annot.roles.contains(t));

        if (!hasRoles) executionCode = 7;
      }

      // Check for channel topics
      if (executionCode == -1 &&
          annot.topics.isNotEmpty &&
          e.channel is TextChannel) {
        var topic = (e.channel as TextChannel).topic;
        var list = topic.split(" ");

        var total = list.any((s) => annot.topics.contains(s));
        if (!total) executionCode = 5;
      }

      // Check if user has required permissions
      if (executionCode == -1 && annot.userPermissions.isNotEmpty) {
        var total = member.effectivePermissions;

        print(annot.userPermissions);
        for (var perm in annot.userPermissions) {
          if (!util.isApplied(perm, total.raw)) {
            executionCode = 1;
            break;
          }
        }
      }

      // Check if bot has required permissions
      if (executionCode == -1 && annot.botPermissions.isNotEmpty) {
        var total = (await e.guild.getMember(client.self)).effectivePermissions;
        for (var perm in annot.botPermissions) {
          if(!util.isApplied(perm, total.raw))
            executionCode = 6;
          break;
        }
      }
    }

    //Check if user is on cooldown
    if (executionCode == -1) {
      if (annot.cooldown != null &&
          annot.cooldown >
              0) if (!(await _cooldownCache.canExecute(
          e.author.id,
          "${meta.parentCommand.name}${meta.methodCommand.name}",
          annot.cooldown * 1000))) executionCode = 2;
    }

    return executionCode;
  }

  // Groups params into
  List<String> _escapeParameters(List<String> splitted) {
    var tmpList = List<String>();
    var isInto = false;

    var finalList = List<String>();

    for (var item in splitted) {
      if (isInto) {
        tmpList.add(item);
        if (item.contains("\"")) {
          isInto = false;
          finalList.add(tmpList.join(" ").replaceAll("\"", ""));
          tmpList.clear();
        }
        continue;
      }

      if (item.contains("\"") && !isInto) {
        isInto = true;
        tmpList.add(item);
        continue;
      }

      finalList.add(item);
    }

    return finalList;
  }

  RegExp _entityRegex = RegExp(r"<(@|@!|@&|#|a?:(.+):)([0-9]+)>");

  Future<List<Object>> _injectParameters(
      MethodMirror method, List<String> splitted, Message e) async {
    var params = method.parameters;

    List<Object> collected = List();
    var index = -1;

    Future<bool> parsePrimitives(Type type) async {
      index++;
      switch (type) {
        case String:
          collected.add(splitted[index]);
          break;
        case int:
          var d = int.parse(splitted[index]);
          collected.add(d);
          break;
        case double:
          var d = double.parse(splitted[index]);
          collected.add(d);
          break;
        case DateTime:
          var d = DateTime.parse(splitted[index]);
          collected.add(d);
          break;
        case Snowflake:
          var id = _entityRegex.firstMatch(splitted[index]).group(3);
          collected.add(Snowflake(id));
          break;
        case TextChannel:
          var id = _entityRegex.firstMatch(splitted[index]).group(3);
          collected.add(e.guild.channels[Snowflake(id)]);
          break;
        case User:
          var id = _entityRegex.firstMatch(splitted[index]).group(3);
          collected.add(client.users[Snowflake(id)]);
          break;
        case Member:
          var id = _entityRegex.firstMatch(splitted[index]).group(3);
          collected.add(e.guild.members[Snowflake(id)]);
          break;
        case Role:
          var id = _entityRegex.firstMatch(splitted[index]).group(3);
          collected.add(e.guild.roles[Snowflake(id)]);
          break;
        case GuildEmoji:
          var id = _entityRegex.firstMatch(splitted[index]).group(3);
          collected.add(e.guild.emojis[Snowflake(id)]);
          break;
        case UnicodeEmoji:
          collected
              .add(util.emojisUnicode[splitted[index]..replaceAll(":", "")] ?? UnicodeEmoji(splitted[index]));
          break;
        default:
          if (_typeConverters == null) return false;

          for (var converter in _typeConverters) {
            if (type == converter._type) {
              var t = converter.parse(splitted[index], e);
              if (t != null) {
                collected.add(t);
                return true;
              }
            }
          }
          return false;
      }

      return true;
    }

    for (var e in params) {
      var type = e.type.reflectedType;
      if (type == CommandContext) continue;

      if (util.getCmdAnnot<Remainder>(e) != null) {
        index++;
        var range = splitted.getRange(index, splitted.length).toList();

        if (type == String) {
          collected.add(range.join(" "));
          break;
        }

        collected.add(range);
        break;
      }

      try {
        var res = await parsePrimitives(type);
        if (res) continue;
      } catch (_) { }

      try {
        collected.add(_services.firstWhere((s) => s.runtimeType == type));
      } catch (_) {
        collected.add(null);
      }
    }

    return collected;
  }

  bool _isUserAdmin(Snowflake authorId, Guild guild) {
    if(guild == null)
      return true;

    return (_admins != null && _admins.any((i) => i == authorId)) ||
        guild.owner.id == authorId;
  }
}
