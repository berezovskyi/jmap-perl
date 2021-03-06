#!/usr/bin/perl -cw

package JMAP::API;

use Carp;
use JMAP::DB;
use strict;
use warnings;
use Encode;
use HTML::GenerateUtil qw(escape_html);
use JSON::XS;
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use JMAP::EmailObject;

my $json = JSON::XS->new->utf8->canonical();

sub new {
  my $class = shift;
  my $db = shift;

  return bless {db => $db}, ref($class) || $class;
}

sub push_results {
  my $Self = shift;
  my $tag = shift;
  foreach my $result (@_) {
    $result->[2] = $tag;
    push @{$Self->{results}}, $result;
    push @{$Self->{resultsbytag}{$tag}}, $result->[1]
      unless $result->[0] eq 'error';
  }
}

sub _parsepath {
  my $path = shift;
  my $item = shift;

  return $item unless $path =~ s{^/([^/]+)}{};
  # rfc6501
  my $selector = $1;
  $selector =~ s{~1}{/}g;
  $selector =~ s{~0}{~}g;

  if (ref($item) eq 'ARRAY') {
    if ($selector eq '*') {
      my @res;
      foreach my $one (@$item) {
        my $res =  _parsepath($path, $one);
        push @res, ref($res) eq 'ARRAY' ? @$res : $res;
      }
      return \@res;
    }
    if ($selector =~ m/^\d+$/) {
      return _parsepath($path, $item->[$selector]);
    }
  }
  if (ref($item) eq 'HASH') {
    return _parsepath($path, $item->{$selector});
  }

  return $item;
}

sub resolve_backref {
  my $Self = shift;
  my $tag = shift;
  my $path = shift;

  my $results = $Self->{resultsbytag}{$tag};
  die "No such result $tag" unless $results;

  my $res = _parsepath($path, @$results);

  $res = [$res] if (defined($res) and ref($res) ne 'ARRAY');
  return $res;
}

sub resolve_args {
  my $Self = shift;
  my $args = shift;
  my %res;
  foreach my $key (keys %$args) {
    if ($key =~ m/^\#(.*)/) {
      my $outkey = $1;
      my $res = eval { $Self->resolve_backref($args->{$key}{resultOf}, $args->{$key}{path}) };
      if ($@) {
        return (undef, { type => 'resultReference', message => $@ });
      }
      $res{$outkey} = $res;
    }
    else {
      $res{$key} = $args->{$key};
    }
  }
  return \%res;
}

sub handle_request {
  my $Self = shift;
  my $request = shift;

  delete $Self->{results};
  delete $Self->{resultsbytag};

  my $methods = $request->{methodCalls};

  foreach my $item (@$methods) {
    my $t0 = [gettimeofday];
    my ($command, $args, $tag) = @$item;
    my @items;
    my $can = $command;
    $can =~ s{/}{_};
    my $FuncRef = $Self->can("api_$can");
    my $logbit = '';
    if ($FuncRef) {
      my ($myargs, $error) = $Self->resolve_args($args);
      if ($myargs) {
        if ($myargs->{ids}) {
          my @list = @{$myargs->{ids}};
          if (@list > 4) {
            my $len = @list;
            $#list = 3;
            $list[3] = '...' . $len;
          }
          $logbit .= " [" . join(",", @list) . "]";
        }
        if ($myargs->{properties}) {
          my @list = @{$myargs->{properties}};
          if (@list > 4) {
            my $len = @list;
            $#list = 3;
            $list[3] = '...' . $len;
          }
          $logbit .= " (" . join(",", @list) . ")";
        }

        @items = eval { $Self->$FuncRef($myargs, $tag) };
        if ($@) {
          @items = ['error', { type => "serverError", message => "$@" }];
          eval { $Self->rollback() };
        }
      }
      else {
        push @items, ['error', $error];
        next;
      }
    }
    else {
      @items = ['error', { type => 'unknownMethod' }];
    }
    $Self->push_results($tag, @items);
    my $elapsed = tv_interval ($t0);
    warn "JMAP CMD $command$logbit took " . $elapsed . "\n";
  }

  return {
    methodResponses => $Self->{results},
  };
}


sub setid {
  my $Self = shift;
  my $key = shift;
  my $val = shift;
  $Self->{idmap}{"#$key"} = $val;
}

sub idmap {
  my $Self = shift;
  my $key = shift;
  return unless $key;
  my $val = exists $Self->{idmap}{$key} ? $Self->{idmap}{$key} : $key;
  return $val;
}

sub api_Calendar_refreshSynced {
  my $Self = shift;

  $Self->{db}->sync_calendars();

  # no response
  return ['Calendar/refreshSynced', {}];
}

sub _filter_list {
  my $list = shift;
  my $ids = shift;

  return $list unless $ids;

  my %map = map { $_ => 1 } @$ids;

  return [ grep { $map{$_->{id}} } @$list ];
}

sub api_UserPreferences_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  my $data = $Self->{db}->dgetcol("juserprefs", {}, 'payload');
  $Self->commit();

  my @list = map { decode_json($_) } @$data;

  my $state = "$user->{jstateUserPreferences}";

# - **remoteServices**: `Object`
#   Maps service type, e.g. 'fs', to an array of services the user has connected to their account, e.g. 'dropbox'.
# - **displayName**: `String`
#   The string to display in the header to identify the account. Normally the email address for the account,
#   but may be different for FastMail users based on a preference).
# - **language**: `String`
#   The language code, e.g. "en-gb", of the user's language
# - **timeZone**: `String`,
#   The Olsen name for the user's time zone.
# - **use24hClock**: `String`
#   One of `'yes'`/`'no'`/`''`. Defaults to '', which means language dependent.
# - **theme**: `String`
#   The name of the theme to use
# - **enableNewsletter**: `booklean`
#   Send newsletters to this account?
# - **defaultIdentityId**: `String`
#   The id of the default personality.
# - **useDefaultFromOnSMTP**: `Boolean`
#   If true, when sending via SMTP the From address will always be set to the default personality,
#   regardless of the address set by the client.
# - **excludeContactsFromBlacklist**: `Boolean`
#   Defaults to true, which means skip the blacklist when processing rules, if the sender of the
#   message is in the user's contacts list.

#   If the language or theme preference is set, the response MUST also set the  appropriate cookie.

  unless (@list) {
    push @list, {
      id => 'singleton',
      remoteServices => {},
      displayName => $user->{displayname} || $user->{email},
      language => 'en-us',
      timeZone => 'Australia/Melbourne',
      use24hClock => 'yes',
      theme => 'default',
      enableNewsletter => $JSON::true,
      defaultIdentityId => 'id1',
      useDefaultFromOnSMTP => $JSON::false,
      excludeContactsFromBlacklist => $JSON::false,
    };
  }

  return ['UserPreferences/get', {
    accountId => $accountid,
    state => $state,
    list => _filter_list(\@list, $args->{ids}),
    notFound => [],
  }];
}

sub update_singleton_value {
  my $Self = shift;
  my $fun = shift;
  my $update = shift;

  my $data = $Self->$fun({ids => ['singleton']});
  my $old = $data->[1]{list}[0];
  foreach my $key (keys %$update) {
    $old->{$key} = $update->{$key};
  }

  return $old;
}

sub api_UserPreferences_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);
  $Self->commit();

  my $oldState = "$user->{jstateUserPreferences}";

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my $created = {};
  my $notCreated = { map { $_ => "Can't create singleton types" } keys %$create };
  my $updated = {};
  my $notUpdated = {};
  foreach my $key (keys %$update) {
    if ($key eq 'singleton') {
      my $value = $Self->update_singleton_value('api_UserPreferences_get', $update->{singleton});
      eval { $Self->{db}->update_prefs('UserPreferences', $value) };
      if ($@) {
        $notUpdated->{singleton} = "$@";
      }
      else {
        $updated->{singleton} = $JSON::true,
      }
    }
    else {
      $notUpdated->{$key} = "Can't update anything except singleton";
    }
  }
  my $destroyed = [];
  my $notDestroyed = { map { $_ => "Can't delete singleton types" } @$destroy };

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  my $newState = "$user->{jstateUserPreferences}";

  my @res;
  push @res, ['UserPreferences/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_ClientPreferences_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  my $data = $Self->{db}->dgetcol("jclientprefs", {}, 'payload');
  $Self->commit();

  my @list = map { eval {decode_json($_)} || () } @$data;

  my $state = "$user->{jstateClientPreferences}";

# - **remoteServices**: `Object`

# - **useSystemFont**: `Boolean`
#   Should the system font be used for the UI rather than FastMail's custom font?
# - **enableKBShortcuts**: `Boolean`
#   Activate keyboard shortcuts?
# - **enableConversations**: `Boolean`
#   Group messages into conversations?
# - **deleteEntireConversation**: `Boolean`
#   Should deleting a conversation delete messages from all folders?
# - **showDeleteWarning**: `Boolean`
#   Should a warning be shown on delete?
# - **showSidebar**: `Boolean`
#   Show a sidebar?
# - **showReadingPane**: `Boolean`
#   Show a reading pane or use separate screens?
# - **showPreview**: `Boolean`
#   Show a preview line on the mailbox screen?
# - **showAvatar**: `Boolean`
#   Show avatars of senders?
# - **afterActionGoTo**: `String`
#   One of `"next"`/`"prev"`/`"mailbox"`. Determines which screen to show
#   next after performing an action in the conversation view.
# - **viewTextOnly**: `Boolean`
#   If true, HTML messages will be converted to plain text before being shown,

  unless (@list) {
    push @list, {
      id => 'singleton',
      useSystemFont => $JSON::false,
      enableKBShortcuts => $JSON::true,
      enableConversations => $JSON::true,
      deleteEntireConversation => $JSON::true,
      showDeleteWarning => $JSON::true,
      showSidebar => $JSON::true,
      showReadingPane => $JSON::false,
      showPreview => $JSON::true,
      showAvatar => $JSON::true,
      afterActionGoTo => 'mailbox',
      viewTextOnly => $JSON::false,
      allowExternalContent => 'always',
      extraHeaders => [],
      autoSaveContacts => $JSON::true,
      replyFromDefault => $JSON::true,
      defaultReplyAll => $JSON::true,
      composeInHTML => $JSON::true,
      replyInOrigFormat => $JSON::true,
      defaultFont => undef,
      defaultSize => undef,
      defaultColour => undef,
      sigPositionOnReply => 'before',
      sigPositionOnForward => 'before',
      replyQuoteAs => 'inline',
      forwardQuoteAs => 'inline',
      replyAttribution => '',
      canWriteSharedContacts => $JSON::false,
      contactsSort => 'lastName',
    };
  }

  return ['ClientPreferences/get', {
    accountId => $accountid,
    state => $state,
    list => _filter_list(\@list, $args->{ids}),
    notFound => [],
  }];
}

sub api_ClientPreferences_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);
  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my $oldState = "$user->{jstateClientPreferences}";

  my $created = {};
  my $notCreated = { map { $_ => "Can't create singleton types" } keys %$create };
  my $updated = {};
  my $notUpdated = {};
  foreach my $key (keys %$update) {
    if ($key eq 'singleton') {
      my $value = $Self->update_singleton_value('api_ClientPreferences_get', $update->{singleton});
      $updated->{singleton} = eval { $Self->{db}->update_prefs('ClientPreferences', $value) };
      $notUpdated->{singleton} = $@ if $@;
    }
    else {
      $notUpdated->{$key} = "Can't update anything except singleton";
    }
  }
  my $destroyed = [];
  my $notDestroyed = { map { $_ => "Can't delete singleton types" } @$destroy };

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  my $newState = "$user->{jstateClientPreferences}";

  my @res;
  push @res, ['ClientPreferences/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_CalendarPreferences_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  my $data = $Self->{db}->dgetcol("jcalendarprefs", {}, 'payload');
  my $defaultCalendar = $Self->{db}->dgetfield('jcalendars', { active => 1 }, 'jcalendarid');
  my ($archiveId) = $Self->{db}->dgetfield('jmailboxes', { role => 'archive', active => 1 }, 'jmailboxid');
  $Self->commit();

  my @list = map { decode_json($_) } @$data;

  my $state = "$user->{jstateCalendarPreferences}";

#- **useTimeZones**: `Boolean`
#  If true, enables multiple time zone support.
#- **firstDayOfWeek**: `Number`
#  0 => Sunday, 1 => Monday, etc. Initially defaults to 1.
#- **showWeekNumbers**: `Boolean`
#  If true, shows week number in overview screen.
#- **showDeclined**: `Boolean`
#  If true, show events that you have RSVPed "no" to.
#- **birthdaysAreVisible**: `Boolean`
#  Should birthdays be shown on the calendar?
#- **defaultCalendarId**: `String`
#  The id of the user's default calendar.
#- **defaultAlerts**: `Alert[]|null`
#  See getCalendarEvents for description of an Alert object.
#- **defaultAllDayAlerts**: `Alert[]|null`
#  See getCalendarEvents for description of an Alert object.
#- **autoAddInvitations**: `Boolean`
#  If true, whenever an event invitation is received, add the event to the user's calendar with the id given in *autoAddCalendarId*.
#- **autoAddCalendarId**: `String`
#  The id of the calendar to auto-add to.
#- **onlyAutoAddIfInGroup**: `Boolean`
#  If true, only automatically add the event if the sender of the invitation is in the contact group given by the *autoAddGroupId* preference.
#- **autoAddGroupId**: `String|null`
#  The id of the contact group to auto-add events from, or null for All Contacts.
#- **markReadAndFileAutoAdd**: `Boolean`
#  If true, for emails where the event is auto-added to the calendar, mark the email as read and file in the folder specified by *autoAddFileIn*.
#- **autoAddFileIn**: `String`
#  The id of the folder to file event invitations in; should default to the Archive folder.
#- **autoUpdate**: `Boolean`
#  If true, whenever an update to an event already in the user's calendar is received, update the event in the user's calendar, or delete it if the event is cancelled.
#- **markReadAndFileAutoUpdate**: `Boolean`
#  If true, for emails where the event is auto-updated, mark the email as read and file in the folder specified by *autoUpdateFileIn*.
#- **autoUpdateFileIn**: `String`
#  The id of the folder to file event updates in; should default to the Archive folder.

  unless (@list) {
    push @list, {
      id => 'singleton',
      useTimeZones => $JSON::false,
      firstDayOfWeek => 1,
      showWeekNumbers => $JSON::false,
      showDeclined => $JSON::false,
      birthdaysAreVisible => $JSON::true,
      defaultCalendar => $defaultCalendar,
      defaultAlerts => undef, 
      defaultAllDayAlerts => undef,
      autoAddInvitations => $JSON::false,
      autoAddCalendar => $JSON::false,
      onlyAutoAddIfInGroup => $JSON::false,
      autoAddGroup => undef,
      markReadAndFileAutoAdd => $JSON::false,
      autoAddFileIn => $archiveId,
      autoUpdate => $JSON::false,
      markReadAndFileAutoUpdate => $JSON::false,
      autoUpdateFileIn => $archiveId,
    };
  }

  return ['CalendarPreferences/get', {
    accountId => $accountid,
    state => $state,
    list => _filter_list(\@list, $args->{ids}),
  }];
}

sub api_CalendarPreferences_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);
  $Self->commit();

  my $oldState = "$user->{jstateCalendarPreferences}";

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my $created = {};
  my $notCreated = { map { $_ => "Can't create singleton types" } keys %$create };
  my $updated = {};
  my $notUpdated = {};
  foreach my $key (keys %$update) {
    if ($key eq 'singleton') {
      my $value = $Self->update_singleton_value('api_CalendarPreferences_get', $update->{singleton});
      $updated->{singleton} = eval { $Self->{db}->update_prefs('CalendarPreferences', $value) };
      $notUpdated->{singleton} = $@ if $@;
    }
    else {
      $notUpdated->{$key} = "Can't update anything except singleton";
    }
  }
  my $destroyed = [];
  my $notDestroyed = { map { $_ => "Can't delete singleton types" } @$destroy };

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();

  my $newState = "$user->{jstateCalendarPreferences}";

  my @res;
  push @res, ['CalendarPreferences/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_VacationResponse_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  return ['VacationReponse/get', {
    accountId => $accountid,
    state => 'dummy',
    list => [{
      id => 'singleton',
      isEnabled => $JSON::false,
      fromDate => undef,
      toDate => undef,
      subject => undef,
      textBody => undef,
      htmlBody => undef,
    }],
    notFound => [],
  }];
}

sub api_Quota_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  my @list = (
    {
      id => 'mail',
      used => 1,
      total => 2,
    },
    {
      id => 'files',
      used => 1,
      total => 2,
    },
  );

  return ['Quota/get', {
    accountId => $accountid,
    state => 'dummy',
    list => _filter_list(\@list, $args->{ids}),
    notFound => [],
  }];
}

sub getSavedSearches {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  my @list;

  return ['savedSearches', {
    accountId => $accountid,
    state => 'dummy',
    list => \@list,
  }];
}

sub api_Identity_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();

  my @list;
  # XXX todo fix Identity
  push @list, {
    id => "id1",
    displayName => $user->{displayname} || $user->{email},
    mayDelete => $JSON::false,
    email => $user->{email},
    name => $user->{displayname} || $user->{email},
    textSignature => "-- \ntext sig",
    htmlSignature => "-- <br><b>html sig</b>",
    replyTo => $user->{email},
    autoBcc => "",
    addBccOnSMTP => $JSON::false,
    saveSentTo => undef,
    saveAttachments => $JSON::false,
    saveOnSMTP => $JSON::false,
    useForAutoReply => $JSON::false,
    isAutoConfigured => $JSON::true,
    enableExternalSMTP => $JSON::false,
    smtpServer => "",
    smtpPort => 465,
    smtpSSL => "ssl",
    smtpUser => "",
    smtpPassword => "",
    smtpRemoteService => undef,
    popLinkId => undef,
  };

  return ['Identity/get', {
    accountId => $accountid,
    state => 'dummy',
    list => \@list,
    notFound => [],
  }];
}

sub begin {
  my $Self = shift;
  $Self->{db}->begin();
}

sub commit {
  my $Self = shift;
  $Self->{db}->commit();
}

sub _transError {
  my $Self = shift;
  if ($Self->{db}->in_transaction()) {
    $Self->{db}->rollback();
  }
  return @_;
}

sub api_Mailbox_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMailbox}";

  my $data = $Self->{db}->dget('jmailboxes', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_->{jmailboxid} => 1 } @$data;
  }

  my %byrole = map { $_->{role} => $_->{jmailboxid} } grep { $_->{role} } @$data;

  my @list;

  foreach my $item (@$data) {
    next unless delete $want{$item->{jmailboxid}};

    my %rights = map { $_ => ($item->{$_} ? $JSON::true : $JSON::false) } qw(mayReadItems mayAddItems mayRemoveItems maySetSeen maySetKeywords mayCreateChild mayRename mayDelete maySubmit);
    my %rec = (
      id => "$item->{jmailboxid}",
      name => Encode::decode_utf8($item->{name}),
      parentId => ($item->{parentId} ? "$item->{parentId}" : undef),
      role => $item->{role},
      sortOrder => $item->{sortOrder}||0,
      (map { $_ => $item->{$_} || 0 } qw(totalEmails unreadEmails totalThreads unreadThreads)),
      myRights => \%rights,
      (map { $_ => ($item->{$_} ? $JSON::true : $JSON::false) } qw(isSubscribed)),
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    push @list, \%rec;
  }

  $Self->commit();

  my %missingids = %want;

  return ['Mailbox/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub _makefullnames {
  my $data = shift;
  my %idmap = map { $_->{jmailboxid} => $_ } @$data;
  my %fullnames;

  delete $idmap{''};  # just in case

  foreach my $id (keys %idmap) {
    my $item = $idmap{$id};
    my @name;
    while ($item) {
      unshift @name, $item->{name};
      $item = $idmap{$item->{parentId}||''};
    }

    $fullnames{$id} = join('\1E', @name);
  }

  return \%fullnames;
}

sub _mailbox_sort {
  my $Self = shift;
  my $data = shift;
  my $sortargs = shift;
  my $storage = shift;

  my %fieldmap = (
    name => ['name', 0],
    sortOrder => ['sortOrder', 1],
  );

  my @res = sort {
    foreach my $arg (@$sortargs) {
      my $res = 0;
      my $field = $arg->{property};
      if ($field eq 'name') {
        $res = $a->{name} cmp $b->{name};
      }
      elsif ($field eq 'sortOrder') {
        $res = $a->{sortOrder} <=> $b->{sortOrder};
      }
      elsif ($field eq 'parent/name') {
        # magic synthentic field... 
        $storage->{fullnames} ||= _makefullnames($storage->{data});
        $res = $storage->{fullnames}{$a->{jmailboxid}} cmp $storage->{fullnames}{$b->{jmailboxid}};
      }
      else {
        die "unknown field $field";
      }

      $res = -$res unless $arg->{isAscending};

      return $res if $res;
    }
    return $a->{jmailboxid} cmp $b->{jmailboxid}; # stable sort
  } @$data;

  return \@res;
}

sub _mailbox_match {
  my $Self = shift;
  my $item = shift;
  my $filter = shift;

  if (exists $filter->{hasRole}) {
    if ($filter->{hasRole}) {
      return 0 unless $item->{role};
    }
    else {
      return 0 if $item->{role};
    }
  }

  if (exists $filter->{parentId}) {
    if ($filter->{parentId}) {
      return 0 unless $item->{parentId};
      return 0 unless $item->{parentId} eq $filter->{parentId};
    }
    else {
      return 0 if $item->{parentId};
    }
  }

  if (exists $filter->{isSubscribed}) {
    if ($filter->{isSubscribed}) {
      return 0 unless $item->{isSubscribed};
    }
    else {
      return 0 if $item->{isSubscribed};
    }
  }

  return 1;
}

sub _mailbox_filter {
  my $Self = shift;
  my $data = shift;
  my $filter = shift;

  return [ grep { $Self->_mailbox_match($_, $filter) } @$data ];
}

sub api_Mailbox_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateMailbox}";

  my $data = $Self->{db}->dget('jmailboxes', { active => 1 });

  $Self->commit();

  my $storage = { data => $data };
  $data = $Self->_mailbox_sort($data, $args->{sort}, $storage);
  $data = $Self->_mailbox_filter($data, $args->{filter}, $storage) if $args->{filter};

  my $start = $args->{position} || 0;

  if ($args->{anchor}) {
    # need to calculate the position
    for (0..$#$data) {
      next unless $data->[$_]{msgid} eq $args->{anchor};
      $start = $_ + $args->{anchorOffset};
      $start = 0 if $start < 0;
      goto gotit;
    }
    return $Self->_transError(['error', {type => 'anchorNotFound'}]);
  }

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_]{jmailboxid} } $start..$end;

  my @res;
  push @res, ['Mailbox/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    canCalculateChanges => $JSON::false,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_Mailbox_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateMailbox}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jmailboxes', { jmodseq => ['>', $sinceState] });

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @created;
  my @updated;
  my @removed;
  my $onlyCounts = 1;
  foreach my $item (@$data) {
    if ($item->{active}) {
      if ($item->{jcreated} <= $sinceState) {
        push @updated, $item->{jmailboxid};
        $onlyCounts = 0 if $item->{jnoncountsmodseq} > $sinceState;
      }
      else {
        push @created, $item->{jmailboxid};
      }
    }
    else {
      if ($item->{jcreated} <= $sinceState) {
        push @removed, $item->{jmailboxid};
      }
      # otherwise never seen
    }
  }

  my @res = (['Mailbox/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    created => [map { "$_" } @created],
    updated => [map { "$_" } @updated],
    removed => [map { "$_" } @removed],
    changedProperties => $onlyCounts ? ["totalEmails", "unreadEmails", "totalThreads", "unreadThreads"] : JSON::null,
  }]);

  return @res;
}

sub _patchitem {
  my $target = shift;
  my $key = shift;
  my $value = shift;

  Carp::confess "missing patch target" unless ref($target) eq 'HASH';

  if ($key =~ s{^([^/]+)/}{}) {
    my $item = $1;
    $item =~ s{~1}{/}g;
    $item =~ s{~0}{~}g;
    return _patchitem($target->{$item}, $key, $value);
  }

  $key =~ s{~1}{/}g;
  $key =~ s{~0}{~}g;

  if (defined $value) {
    $target->{$key} = $value;
  }
  else {
    delete $target->{$key};
  }
}

sub _resolve_patch {
  my $Self = shift;
  my $update = shift;
  my $method = shift;
  foreach my $id (keys %$update) {
    my %keys;
    foreach my $key (sort keys %{$update->{$id}}) {
      next unless $key =~ m{([^/]+)/};
      push @{$keys{$1}}, $key;
    }
    next unless keys %keys; # nothing patched in this one
    my $data = $Self->$method({ids => [$id], properties => [keys %keys]});
    my $list = $data->[1]{list};
    # XXX - if nothing in the list we SHOULD abort
    next unless $list->[0];
    foreach my $key (keys %keys) {
      $update->{$id}{$key} = $list->[0]{$key};
      _patchitem($update->{$id}, $_ => delete $update->{$id}{$_}) for @{$keys{$key}};
    }
  }
}

sub api_Mailbox_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  # make sure our DB is up to date - happy to enforce this because folder names
  # are a unique namespace, so we should try to minimise the race time
  $Self->{db}->sync_folders();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $Self->commit();
  $oldState = "$user->{jstateMailbox}";

  ($created, $notCreated) = $Self->{db}->create_mailboxes($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_Mailbox_get');
  ($updated, $notUpdated) = $Self->{db}->update_mailboxes($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_mailboxes($destroy, $Self->{onDestroyRemoveMessages});

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  $newState = "$user->{jstateMailbox}";

  my @res;
  push @res, ['Mailbox/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub _post_sort {
  my $Self = shift;
  my $data = shift;
  my $sortargs = shift; 
  my $storage = shift;

  my %fieldmap = (
    id => ['msgid', 0],
    receivedAt => ['internaldate', 1],
    sentAt => ['msgdate', 1],
    size => ['msgsize', 1],
    isunread => ['isUnread', 1],
    subject => ['sortsubject', 0],
    from => ['msgfrom', 0],
    to => ['msgto', 0],
  );

  my @res = sort {
    foreach my $arg (@$sortargs) {
      my $res = 0;
      my $field = $arg->{property};
      my $map = $fieldmap{$field};
      if ($map) {
        if ($map->[1]) {
          $res = $a->{$map->[0]} <=> $b->{$map->[0]};
        }
        else {
          $res = $a->{$map->[0]} cmp $b->{$map->[0]};
        }
      }
      elsif ($field =~ m/^keyword:(.*)/) {
        my $keyword = $1;
        my $av = $a->{keywords}{$keyword} ? 1 : 0;
        my $bv = $b->{keywords}{$keyword} ? 1 : 0;
        $res = $av <=> $bv;
      }
      elsif ($field =~ m/^allInThreadHaveKeyword:(.*)/) {
        my $keyword = $1;
        $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
        my $av = ($storage->{hasthreadkeyword}{$a->{thrid}}{$keyword} || 0) == 2 ? 1 : 0;
        my $bv = ($storage->{hasthreadkeyword}{$b->{thrid}}{$keyword} || 0) == 2 ? 1 : 0;
        $res = $av <=> $bv;
      }
      elsif ($field =~ m/^someInThreadHaveKeyword:(.*)/) {
        my $keyword = $1;
        $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
        my $av = ($storage->{hasthreadkeyword}{$a->{thrid}}{$keyword} || 0) ? 1 : 0;
        my $bv = ($storage->{hasthreadkeyword}{$b->{thrid}}{$keyword} || 0) ? 1 : 0;
        $res = $av <=> $bv;
      }
      else {
        die "unknown field $field";
      }

      $res = -$res unless $arg->{isAscending};

      return $res if $res;
    }
    return $a->{msgid} cmp $b->{msgid}; # stable sort
  } @$data;

  return \@res;
}

sub _load_mailbox {
  my $Self = shift;
  my $id = shift;

  $Self->begin();
  my $data = $Self->{db}->dgetby('jmessagemap', 'msgid', { jmailboxid => $id }, 'msgid,jmodseq,active');
  $Self->commit();

  return $data;
}

sub _load_msgmap {
  my $Self = shift;
  my $id = shift;

  $Self->begin();
  my $data = $Self->{db}->dget('jmessagemap', {}, 'msgid,jmailboxid,jmodseq,active');
  $Self->commit();
  my %map;
  foreach my $row (@$data) {
    $map{$row->{msgid}}{$row->{jmailboxid}} = $row;
  }
  return \%map;
}

sub _load_hasatt {
  my $Self = shift;
  $Self->begin();
  my $data = $Self->{db}->dgetcol('jrawmessage', { hasAttachment => 1 }, 'msgid');
  $Self->commit();
  return { map { $_ => 1 } @$data };
}

sub _hasthreadkeyword {
  my $data = shift;
  my %res;
  foreach my $item (@$data) {
    next unless $item->{active};  # we get called by getEmailListUpdates, which includes inactive messages

    # have already seen a message for this thread
    if ($res{$item->{thrid}}) {
      foreach my $keyword (keys %{$item->{keywords}}) {
        # if not already known about, it wasn't present on previous messages, so it's a "some"
        $res{$item->{thrid}}{$keyword} ||= 1;
      }
      foreach my $keyword (keys %{$res{$item->{thrid}}}) {
        # if it was known already, but isn't on this one, it's a some
        $res{$item->{thrid}}{$keyword} = 1 unless $item->{keywords}{$keyword};
      }
    }

    # first message, it's "all" for every keyword
    else {
      $res{$item->{thrid}} = { map { $_ => 2 } keys %{$item->{keywords}} };
    }
  }
  return \%res;
}

sub _match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  return $Self->_match_operator($item, $condition, $storage) if $condition->{operator};

  if ($condition->{inMailbox}) {
    my $id = $Self->idmap($condition->{inMailbox});
    $storage->{mailbox}{$id} ||= $Self->_load_mailbox($id);
    return 0 unless $storage->{mailbox}{$id}{$item->{msgid}}{active};
  }

  if ($condition->{inMailboxOtherThan}) {
    $storage->{msgmap} ||= $Self->_load_msgmap();
    my $cond = $condition->{inMailboxOtherThan};
    $cond = [$cond] unless ref($cond) eq 'ARRAY';  # spec and possible change
    my %match = map { $Self->idmap($_) => 1 } @$cond;
    my $data = $storage->{msgmap}{$item->{msgid}} || {};
    my $inany = 0;
    foreach my $id (keys %$data) {
      next if $match{$id};
      next unless $data->{$id}{active};
      $inany = 1;
    }
    return 0 unless $inany;
  }

  if ($condition->{before}) {
    my $time = str2time($condition->{before});
    return 0 unless $item->{internaldate} < $time;
  }

  if ($condition->{after}) {
    my $time = str2time($condition->{after});
    return 0 unless $item->{internaldate} >= $time;
  }

  if ($condition->{minSize}) {
    return 0 unless $item->{msgsize} >= $condition->{minSize};
  }

  if ($condition->{maxSize}) {
    return 0 unless $item->{msgsize} < $condition->{maxSize};
  }

  # 2 == all
  # 1 == some
  # non-existent means none, of course
  if ($condition->{allInThreadHaveKeyword}) {
    # XXX case?
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{allInThreadHaveKeyword}};
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{allInThreadHaveKeyword}} == 2;
  }

  if ($condition->{someInThreadHaveKeyword}) {
    # XXX case?
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{someInThreadHaveKeyword}};
  }

  if ($condition->{noneInThreadHaveKeyword}) {
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 if $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{noneInThreadHaveKeyword}};
  }

  if ($condition->{hasKeyword}) {
    return 0 unless $item->{keywords}->{$condition->{hasKeyword}};
  }

  if ($condition->{notKeyword}) {
    return 0 if $item->{keywords}->{$condition->{notKeyword}};
  }

  if ($condition->{hasAttachment}) {
    $storage->{hasatt} ||= $Self->_load_hasatt();
    return 0 unless $storage->{hasatt}{$item->{msgid}};
    # XXX - hasAttachment
  }

  if ($condition->{text}) {
    $storage->{textsearch}{$condition->{text}} ||= $Self->{db}->imap_search('text', $condition->{text});
    return 0 unless $storage->{textsearch}{$condition->{text}}{$item->{msgid}};
  }

  if ($condition->{from}) {
    $storage->{fromsearch}{$condition->{from}} ||= $Self->{db}->imap_search('from', $condition->{from});
    return 0 unless $storage->{fromsearch}{$condition->{from}}{$item->{msgid}};
  }

  if ($condition->{to}) {
    $storage->{tosearch}{$condition->{to}} ||= $Self->{db}->imap_search('to', $condition->{to});
    return 0 unless $storage->{tosearch}{$condition->{to}}{$item->{msgid}};
  }

  if ($condition->{cc}) {
    $storage->{ccsearch}{$condition->{cc}} ||= $Self->{db}->imap_search('cc', $condition->{cc});
    return 0 unless $storage->{ccsearch}{$condition->{cc}}{$item->{msgid}};
  }

  if ($condition->{bcc}) {
    $storage->{bccsearch}{$condition->{bcc}} ||= $Self->{db}->imap_search('bcc', $condition->{bcc});
    return 0 unless $storage->{bccsearch}{$condition->{bcc}}{$item->{msgid}};
  }

  if ($condition->{subject}) {
    $storage->{subjectsearch}{$condition->{subject}} ||= $Self->{db}->imap_search('subject', $condition->{subject});
    return 0 unless $storage->{subjectsearch}{$condition->{subject}}{$item->{msgid}};
  }

  if ($condition->{body}) {
    $storage->{bodysearch}{$condition->{body}} ||= $Self->{db}->imap_search('body', $condition->{body});
    return 0 unless $storage->{bodysearch}{$condition->{body}}{$item->{msgid}};
  }

  if ($condition->{header}) {
    my $cond = $condition->{header};
    $cond->[1] = '' if @$cond == 1;
    my $storekey = join(',', @$cond);
    $storage->{headersearch}{$storekey} ||= $Self->{db}->imap_search('header', @$cond);
    return 0 unless $storage->{headersearch}{$storekey}{$item->{msgid}};
  }

  return 1;
}

sub _match_operator {
  my $Self = shift;
  my ($item, $filter, $storage) = @_;
  if ($filter->{operator} eq 'NOT') {
    return not $Self->_match_operator($item, {operator => 'OR', conditions => $filter->{conditions}}, $storage);
  }
  elsif ($filter->{operator} eq 'OR') {
    foreach my $condition (@{$filter->{conditions}}) {
      return 1 if $Self->_match($item, $condition, $storage);
    }
    return 0;
  }
  elsif ($filter->{operator} eq 'AND') {
    foreach my $condition (@{$filter->{conditions}}) {
      return 0 if not $Self->_match($item, $condition, $storage);
    }
    return 1;
  }
  die "Invalid operator $filter->{operator}";
}

sub _messages_filter {
  my $Self = shift;
  my ($data, $filter, $storage) = @_;
  return [ grep { $Self->_match($_, $filter, $storage) } @$data ];
}

sub _collapse_messages {
  my $Self = shift;
  my ($data) = @_;
  my @res;
  my %seen;
  foreach my $item (@$data) {
    next if $seen{$item->{thrid}};
    push @res, $item;
    $seen{$item->{thrid}} = 1;
  }
  return \@res;
}

sub api_Email_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (exists $args->{position} and exists $args->{anchor});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (exists $args->{anchor} and not exists $args->{anchorOffset});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (not exists $args->{anchor} and exists $args->{anchorOffset});

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}]) if $start < 0;

  my $data = $Self->{db}->dget('jmessages', { active => 1 });

  # commit before applying the filter, because it might call out for searches
  $Self->commit();

  map { $_->{keywords} = decode_json($_->{keywords} || {}) } @$data;
  my $storage = {data => $data};
  $data = $Self->_post_sort($data, $args->{sort}, $storage);
  $data = $Self->_messages_filter($data, $args->{filter}, $storage) if $args->{filter};
  $data = $Self->_collapse_messages($data) if $args->{collapseThreads};

  if ($args->{anchor}) {
    # need to calculate the position
    for (0..$#$data) {
      next unless $data->[$_]{msgid} eq $args->{anchor};
      $start = $_ + $args->{anchorOffset};
      $start = 0 if $start < 0;
      goto gotit;
    }
    return $Self->_transError(['error', {type => 'anchorNotFound'}]);
  }

gotit:

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_]{msgid} } $start..$end;

  my @res;
  push @res, ['Email/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    collapseThreads => $args->{collapseThreads},
    queryState => $newQueryState,
    canCalculateChanges => $JSON::true,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_Email_queryChanges {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceQueryState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    if ($user->{jdeletedmodseq} and $args->{sinceQueryState} <= $user->{jdeletedmodseq});

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $data = $Self->{db}->dget('jmessages', {});

  $Self->commit();

  map { $_->{keywords} = decode_json($_->{keywords} || {}) } @$data;
  my $storage = {data => $data};
  $data = $Self->_post_sort($data, $args->{sort}, $storage);

  # now we have the same sorted data set.  What we DON'T have is knowing that a message used to be in the filter,
  # but no longer is (aka isUnread).  There's no good way to do this :(  So we have to assume that every message
  # which is changed and NOT in the dataset used to be...

  # we also have to assume that it MIGHT have been the exemplar...

  my $tell = 1;
  my $total = 0;
  my $changes = 0;
  my @added;
  my @removed;
  # just do two entire logic paths, it's different enough to make it easier to write twice
  if ($args->{collapseThreads}) {
    # exemplar - only these messages are in the result set we're building
    my %exemplar;
    # finished - we've told about both the exemplar, and guaranteed to have told about all
    # the messages that could possibly have been the previous exemplar (at least one
    # non-deleted, unchanged message)
    my %finished;
    foreach my $item (@$data) {
      # we don't have to tell anything about finished threads, not even check them for membership in the search
      next if $finished{$item->{thrid}};

      # deleted is the same as not in filter for our purposes
      my $isin = $item->{active} ? ($args->{filter} ? $Self->_match($item, $args->{filter}, $storage) : 1) : 0;

      # only exemplars count for the total - we need to know total even if not telling any more
      if ($isin and not $exemplar{$item->{thrid}}) {
        $total++;
        $exemplar{$item->{thrid}} = $item->{msgid};
      }
      next unless $tell;

      # jmodseq greater than sinceQueryState is a change
      my $changed = ($item->{jmodseq} > $args->{sinceQueryState});
      my $isnew = ($item->{jcreated} > $args->{sinceQueryState});

      if ($changed) {
        # if it's in AND it's the exemplar, it's been added
        if ($isin and $exemplar{$item->{thrid}} eq $item->{msgid}) {
          push @added, {id => "$item->{msgid}", index => $total-1};
          push @removed, "$item->{msgid}";
          $changes++;
        }
        # otherwise it's removed
        else {
          push @removed, "$item->{msgid}";
          $changes++;
        }
      }
      # unchanged and isin, final candidate for old exemplar!
      elsif ($isin) {
        # remove it unless it's also the current exemplar
        if ($exemplar{$item->{thrid}} ne $item->{msgid}) {
          push @removed, "$item->{msgid}";
          $changes++;
        }
        # and we're done
        $finished{$item->{thrid}} = 1;
      }

      if ($args->{maxChanges} and $changes > $args->{maxChanges}) {
        return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}]);
      }

      if ($args->{upToEmailId} and $args->{upToEmailId} eq $item->{msgid}) {
        # stop mentioning changes
        $tell = 0;
      }
    }
  }

  # non-collapsed case
  else {
    foreach my $item (@$data) {
      # deleted is the same as not in filter for our purposes
      my $isin = $item->{active} ? ($args->{filter} ? $Self->_match($item, $args->{filter}, $storage) : 1) : 0;

      # all active messages count for the total
      $total++ if $isin;
      next unless $tell;

      # jmodseq greater than sinceQueryState is a change
      my $changed = ($item->{jmodseq} > $args->{sinceQueryState});
      my $isnew = ($item->{jcreated} > $args->{sinceQueryState});

      if ($changed) {
        if ($isin) {
          push @added, {id => "$item->{msgid}", index => $total-1};
          push @removed, "$item->{msgid}";
          $changes++;
        }
        else {
          push @removed, "$item->{msgid}";
          $changes++;
        }
      }

      if ($args->{maxChanges} and $changes > $args->{maxChanges}) {
        return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}]);
      }

      if ($args->{upToEmailId} and $args->{upToEmailId} eq $item->{msgid}) {
        # stop mentioning changes
        $tell = 0;
      }
    }
  }

  my @res;
  push @res, ['Email/queryChanges', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    collapseThreads => $args->{collapseThreads},
    oldQueryState => "$args->{sinceQueryState}",
    newQueryState => $newQueryState,
    removed => \@removed,
    added => \@added,
    total => $total,
  }];

  return @res;
}

sub _extract_terms {
  my $filter = shift;
  return () unless $filter;
  return map { _extract_terms($_) } @$filter if ref($filter) eq 'ARRAY';
  my @list;
  push @list, _extract_terms($filter->{conditions});
  push @list, $filter->{body} if $filter->{body};
  push @list, $filter->{text} if $filter->{text};
  push @list, $filter->{subject} if $filter->{subject};
  return @list;
}

sub api_SearchSnippet_get {
  my $Self = shift;
  my $args = shift;

  my $messages = $Self->api_Email_get({
    accountId => $args->{accountId},
    ids => $args->{emailIds},
    properties => ['subject', 'textBody', 'preview'],
  });

  return $messages unless $messages->[0] eq 'Email/get';
  $messages->[0] = 'SearchSnippet/get';
  delete $messages->[1]{state};
  $messages->[1]{filter} = $args->{filter};
  $messages->[1]{collapseThreads} = $args->{collapseThreads}, # work around client bug

  my @terms = _extract_terms($args->{filter});
  my $str = join("|", @terms);
  my $tag = 'mark';
  foreach my $item (@{$messages->[1]{list}}) {
    $item->{emailId} = delete $item->{id};
    my $text = delete $item->{textBody};
    $item->{subject} = escape_html($item->{subject});
    $item->{preview} = escape_html($item->{preview});
    next unless @terms;
    $item->{subject} =~ s{\b($str)\b}{<$tag>$1</$tag>}gsi;
    if ($text =~ m{(.{0,20}\b(?:$str)\b.*)}gsi) {
      $item->{preview} = substr($1, 0, 200);
      $item->{preview} =~ s{^\s+}{}gs;
      $item->{preview} =~ s{\s+$}{}gs;
      $item->{preview} =~ s{[\r\n]+}{ -- }gs;
      $item->{preview} =~ s{\s+}{ }gs;
      $item->{preview} = escape_html($item->{preview});
      $item->{preview} =~ s{\b($str)\b}{<$tag>$1</$tag>}gsi;
    }
    $item->{body} = $item->{preview}; # work around client bug
  }

  return $messages;
}

sub api_Email_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $args->{ids};
  #properties: String[] A list of properties to fetch for each message.

  # XXX - lots to do about properties here
  my %seenids;
  my %missingids;
  my @list;
  my $need_content = 0;
  foreach my $prop (qw(hasAttachment headers preview textBody htmlBody attachments attachedEmails)) {
    $need_content = 1 if _prop_wanted($args, $prop);
  }
  $need_content = 1 if ($args->{properties} and grep { m/^headers\./ } @{$args->{properties}});
  my %msgidmap;
  foreach my $msgid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$msgid};
    $seenids{$msgid} = 1;
    my $data = $Self->{db}->dgetone('jmessages', { msgid => $msgid });
    unless ($data) {
      $missingids{$msgid} = 1;
      next;
    }

    $msgidmap{$msgid} = $data->{msgid};
    my $item = {
      id => "$msgid",
    };

    if (_prop_wanted($args, 'threadId')) {
      $item->{threadId} = "$data->{thrid}";
    }

    if (_prop_wanted($args, 'mailboxIds')) {
      my $ids = $Self->{db}->dgetcol('jmessagemap', { msgid => $msgid, active => 1 }, 'jmailboxid');
      $item->{mailboxIds} = {map { $_ => $JSON::true } @$ids};
    }

    if (_prop_wanted($args, 'inReplyToEmailId')) {
      $item->{inReplyToEmailId} = $data->{msginreplyto};
    }

    if (_prop_wanted($args, 'hasAttachment')) {
      $item->{hasAttachment} = $data->{hasAttachment} ? $JSON::true : $JSON::false;
    }

    if (_prop_wanted($args, 'keywords')) {
      $item->{keywords} = decode_json($data->{keywords});
    }

    foreach my $email (qw(to cc bcc from replyTo)) {
      if (_prop_wanted($args, $email)) {
        $item->{$email} = JMAP::EmailObject::asAddresses($data->{"msg$email"});
      }
    }

    if (_prop_wanted($args, 'subject')) {
      $item->{subject} = Encode::decode_utf8($data->{msgsubject});
    }

    if (_prop_wanted($args, 'sentAt')) {
      $item->{sentAt} = JMAP::EmailObject::isodate($data->{msgdate});
    }

    if (_prop_wanted($args, 'receivedAt')) {
      $item->{receivedAt} = JMAP::EmailObject::isodate($data->{internaldate});
    }

    if (_prop_wanted($args, 'size')) {
      $item->{size} = $data->{msgsize};
    }

    if (_prop_wanted($args, 'blobId')) {
      $item->{blobId} = "m-$msgid";
    }

    push @list, $item;
  }

  $Self->commit();

  # need to load messages from the server
  if ($need_content) {
    my $content = $Self->{db}->fill_messages(map { $_->{id} } @list);
    foreach my $item (@list) {
      my $data = $content->{$item->{id}};
      foreach my $prop (qw(preview textBody htmlBody)) {
        if (_prop_wanted($args, $prop)) {
          $item->{$prop} = $data->{$prop};
        }
      }
      if (_prop_wanted($args, 'body')) {
        if ($data->{htmlBody}) {
          $item->{htmlBody} = $data->{htmlBody};
        }
        else {
          $item->{textBody} = $data->{textBody};
        }
      }
      if (exists $item->{textBody} and not $item->{textBody}) {
        $item->{textBody} = JMAP::DB::htmltotext($data->{htmlBody});
      }
      if (_prop_wanted($args, 'hasAttachment')) {
        $item->{hasAttachment} = $data->{hasAttachment} ? $JSON::true : $JSON::false;
      }
      if (_prop_wanted($args, 'headers')) {
        $item->{headers} = $data->{headers};
      }
      elsif ($args->{properties}) {
        my %wanted;
        foreach my $prop (@{$args->{properties}}) {
          next unless $prop =~ m/^headers\.(.*)/;
          $item->{headers} ||= {}; # avoid zero matched headers bug
          $wanted{lc $1} = 1;
        }
        foreach my $key (keys %{$data->{headers}}) {
          next unless $wanted{lc $key};
          $item->{headers}{lc $key} = $data->{headers}{$key};
        }
      }
      if (_prop_wanted($args, 'attachments')) {
        $item->{attachments} = $data->{attachments};
      }
      if (_prop_wanted($args, 'attachedEmails')) {
        $item->{attachedEmails} = $data->{attachedEmails};
      }
    }
  }

  return ['Email/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

# NOT AN API CALL as such...
sub getRawBlob {
  my $Self = shift;
  my $selector = shift;

  return () unless $selector =~ m{([mf]-[^/]+)/(.*)};
  my $blobId = $1;
  my $filename = $2;

  my ($type, $data) = $Self->{db}->get_blob($blobId);

  return ($type, $data, $filename);
}

# or this
sub uploadFile {
  my $Self = shift;
  my ($accountid, $type, $content) = @_; # XXX filehandle?

  return $Self->{db}->put_file($accountid, $type, $content);
}

sub downloadFile {
  my $Self = shift;
  my $jfileid = shift;

  my ($type, $content) = $Self->{db}->get_file($jfileid);

  return ($type, $content);
}

sub api_Email_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jmessages', { jmodseq => ['>', $args->{sinceState}] }, 'msgid,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @created;
  my @updated;
  my @removed;

  foreach my $row (@$data) {
    if ($row->{active}) {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @updated, $row->{msgid};
      } else {
        push @created, $row->{msgid};
      }
    }
    else {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @removed, $row->{msgid};
      }
      # otherwise never seen
    }
  }

  my @res;
  push @res, ['Email/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    created => [map { "$_" } @created],
    updated => [map { "$_" } @updated],
    removed => [map { "$_" } @removed],
  }];

  return @res;
}

sub api_Email_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  # get state up-to-date first
  $Self->{db}->sync_imap();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $Self->commit();
  $oldState = "$user->{jstateEmail}";

  ($created, $notCreated) = $Self->{db}->create_messages($create, sub { $Self->idmap(shift) });
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_Email_get');
  ($updated, $notUpdated) = $Self->{db}->update_messages($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_messages($destroy);

  # XXX - cheap dumb racy version
  $Self->{db}->sync_imap();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  $newState = "$user->{jstateEmail}";

  foreach my $cid (sort keys %$created) {
    my $msgid = $created->{$cid}{id};
    $created->{$cid}{blobId} = "m-$msgid";
  }

  my @res;
  push @res, ['Email/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_Email_import {
  my $Self = shift;
  my $args = shift;

  my %created;
  my %notcreated;

  my $scoped_lock = $Self->{db}->begin_superlock();

  # make sure our DB is up to date
  $Self->{db}->sync_folders();

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if (not $args->{messages} or ref($args->{messages}) ne 'HASH');

  my $mailboxdata = $Self->dget('jmailboxes', { active => 1 });
  my %validids = map { $_->{jmailboxid} => 1 } @$mailboxdata;

  foreach my $id (keys %{$args->{messages}}) {
    my $message = $args->{messages}{$id};
    # sanity check
    return $Self->_transError(['error', {type => 'invalidArguments'}])
      if (not $message->{mailboxIds} or ref($message->{mailboxIds}) ne 'HASH');
    return $Self->_transError(['error', {type => 'invalidArguments'}])
      if (not $message->{blobId});
  }

  $Self->commit();

  my %todo;
  foreach my $id (keys %{$args->{messages}}) {
    my $message = $args->{messages}{$id};
    my @ids = map { $Self->idmap($_) } keys %{$message->{mailboxIds}};
    if (grep { not $validids{$_} } @ids) {
      $notcreated{$id} = { type => 'invalidMailboxes' };
      next;
    }

    my ($type, $file) = $Self->{db}->get_file($message->{blobId});
    unless ($file) {
      $notcreated{$id} = { type => 'notFound' };
      next;
    }

    unless ($type eq 'message/rfc822') {
      $notcreated{$id} = { type => 'notFound', description => "incorrect type $type for $message->{blobId}" };
      next;
    }

    my ($msgid, $thrid, $size) = eval { $Self->{db}->import_message($file, \@ids, $message->{keywords}) };
    if ($@) {
      $notcreated{$id} = { type => 'internalError', description => $@ };
      next;
    }

    $created{$id} = {
      id => $msgid,
      blobId => $message->{blobId},
      threadId => $thrid,
      size => $size,
    };
  }

  my @res;
  push @res, ['Email/import', {
    accountId => $accountid,
    created => \%created,
    notCreated => \%notcreated,
  }];

  return @res;
}

sub api_Email_copy {
  my $Self = shift;
  return $Self->_transError(['error', {type => 'notImplemented'}]);
}

sub reportEmails {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{emailIds};

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not exists $args->{asSpam};

  $Self->commit();

  my @ids = map { $Self->idmap($_) } @{$args->{emailIds}};
  my ($reported, $notfound) = $Self->report_messages(\@ids, $args->{asSpam});

  my @res;
  push @res, ['messagesReported', {
    accountId => $Self->{db}->accountid(),
    asSpam => $args->{asSpam},
    reported => $reported,
    notFound => $notfound,
  }];

  return @res;
}

sub api_Thread_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateThread}";

  # XXX - error if no IDs

  my @list;
  my %seenids;
  my %missingids;
  foreach my $thrid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$thrid};
    $seenids{$thrid} = 1;
    my $data = $Self->{db}->dgetfield('jthreads', { thrid => $thrid, active => 1 }, 'data');
    unless ($data) {
      $missingids{$thrid} = 1;
      next;
    }
    my $jdata = $json->decode($data);
    push @list, {
      id => "$thrid",
      emailIds => [ map { "$_" } @$jdata ],
    };
  }

  $Self->commit();

  my @res;
  push @res, ['Thread/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];

  return @res;
}

sub api_Thread_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateThread}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jthreads', { jmodseq => ['>', $args->{sinceState}] }, 'thrid,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @created;
  my @updated;
  my @removed;
  foreach my $row (@$data) {
    if ($row->{active}) {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @updated, $row->{thrid};
      }
      else {
        push @created, $row->{thrid};
      }
    }
    else {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @removed, $row->{thrid};
      }
      # otherwise never seen
    }
  }

  my @res;
  push @res, ['Thread/changes', {
    accountId => $accountid,
    oldState => $args->{sinceState},
    newState => $newState,
    created => \@created,
    updated => \@updated,
    removed => \@removed,
  }];

  return @res;
}

sub _prop_wanted {
  my $args = shift;
  my $prop = shift;
  return 1 if $prop eq 'id'; # MUST ALWAYS RETURN id
  return 1 unless $args->{properties};
  return 1 if grep { $_ eq $prop } @{$args->{properties}};
  return 0;
}

sub getCalendarPreferences {
  return ['calendarPreferences', {
    autoAddCalendarId         => '',
    autoAddInvitations        => JSON::false,
    autoAddGroupId            => JSON::null,
    autoRSVPGroupId           => JSON::null,
    autoRSVP                  => JSON::false,
    autoUpdate                => JSON::false,
    birthdaysAreVisible       => JSON::false,
    defaultAlerts             => {},
    defaultAllDayAlerts       => {},
    defaultCalendarId         => '',
    firstDayOfWeek            => 1,
    markReadAndFileAutoAdd    => JSON::false,
    markReadAndFileAutoUpdate => JSON::false,
    onlyAutoAddIfInGroup      => JSON::false,
    onlyAutoRSVPIfInGroup     => JSON::false,
    showWeekNumbers           => JSON::false,
    timeZone                  => JSON::null,
    useTimeZones              => JSON::false,
  }];
}

sub api_Calendar_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendar}";

  my $data = $Self->{db}->dget('jcalendars', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_->{jcalendarid} => 1 } @$data;
  }

  my @list;

  foreach my $item (@$data) {
    next unless delete $want{$item->{jcalendarid}};

    my %rec = (
      id => "$item->{jcalendarid}",
      name => "$item->{name}",
      color => "$item->{color}",
      isVisible => $item->{isVisible} ? $JSON::true : $JSON::false,
      mayReadFreeBusy => $item->{mayReadFreeBusy} ? $JSON::true : $JSON::false,
      mayReadItems => $item->{mayReadItems} ? $JSON::true : $JSON::false,
      mayAddItems => $item->{mayAddItems} ? $JSON::true : $JSON::false,
      mayModifyItems => $item->{mayModifyItems} ? $JSON::true : $JSON::false,
      mayRemoveItems => $item->{mayRemoveItems} ? $JSON::true : $JSON::false,
      mayDelete => $item->{mayDelete} ? $JSON::true : $JSON::false,
      mayRename => $item->{mayRename} ? $JSON::true : $JSON::false,
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    push @list, \%rec;
  }

  $Self->commit();

  my %missingids = %want;

  return ['Calendar/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_Calendar_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendar}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jcalendars', {}, 'jcalendarid,jmodseq,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @created;
  my @updated;
  my @removed;
  foreach my $item (@$data) {
    if ($item->{jmodseq} > $sinceState) {
      if ($item->{active}) {
        if ($item->{jcreated} <= $sinceState) {
          push @updated, $item->{jcalendarid};
        }
        else {
          push @created, $item->{jcalendarid};
        }
      }
      else {
        if ($item->{jcreated} <= $sinceState) {
          push @removed, $item->{jcalendarid};
        }
        # otherwise never seen
      }
    }
  }

  my @res = (['Calendar/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    created => [map { "$_" } @created],
    updated => [map { "$_" } @updated],
    removed => [map { "$_" } @removed],
  }]);

  return @res;
}

sub _event_match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  # XXX - condition handling code
  if ($condition->{inCalendars}) {
    my $match = 0;
    foreach my $id (@{$condition->{inCalendars}}) {
      next unless $item->{jcalendarid} eq $id;
      $match = 1;
    }
    return 0 unless $match;
  }

  return 1;
}

sub _event_filter {
  my $Self = shift;
  my ($data, $filter, $storage) = @_;
  my @res;
  foreach my $item (@$data) {
    next unless $Self->_event_match($item, $filter, $storage);
    push @res, $item;
  }
  return \@res;
}

sub api_CalendarEvent_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateCalendarEvent}";

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $data = $Self->{db}->dget('jevents', { active => 1 }, 'eventuid,jcalendarid');

  $data = $Self->_event_filter($data, $args->{filter}, {}) if $args->{filter};

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_]{eventuid} } $start..$end;

  $Self->commit();

  my @res;
  push @res, ['CalendarEvent/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_CalendarEvent_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendarEvent}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $args->{ids};
  #properties: String[] A list of properties to fetch for each message.

  my %seenids;
  my %missingids;
  my @list;
  foreach my $eventuid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$eventuid};
    $seenids{$eventuid} = 1;

    my $data = $Self->{db}->dgetone('jevents', { eventuid => $eventuid }, 'jcalendarid,payload');
    unless ($data) {
      $missingids{$eventuid} = 1;
      next;
    }

    my $item = decode_json($data->{payload});

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    $item->{id} = $eventuid;
    $item->{calendarId} = "$data->{jcalendarid}" if _prop_wanted($args, "calendarId");

    push @list, $item;
  }

  $Self->commit();

  return ['CalendarEvent/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_CalendarEvent_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateCalendarEvent}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jevents', { jmodseq => ['>', $args->{sinceState}] }, 'eventuid,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @created;
  my @updated;
  my @removed;

  foreach my $row (@$data) {
    if ($row->{active}) {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @updated, $row->{eventuid};
      }
      else {
        push @created, $row->{eventuid};
      }
    }
    else {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @removed, $row->{eventuid};
      }
      # otherwise never seen
    }
  }

  my @res;
  push @res, ['CalendarEvent/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    created => [map { "$_" } @created],
    updated => [map { "$_" } @updated],
    removed => [map { "$_" } @removed],
  }];

  return @res;
}

sub api_Addressbook_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  # we have no datatype for this yet
  my $newState = "$user->{jhighestmodseq}";

  my $data = $Self->{db}->dget('jaddressbooks', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_->{jaddressbookid} => 1 } @$data;
  }

  my @list;

  foreach my $item (@$data) {
    next unless delete $want{$item->[0]};

    my %rec = (
      id => "$item->{jaddressbookid}",
      name => "$item->{name}",
      isVisible => $item->{isVisible} ? $JSON::true : $JSON::false,
      mayReadItems => $item->{mayReadItems} ? $JSON::true : $JSON::false,
      mayAddItems => $item->{mayAddItems} ? $JSON::true : $JSON::false,
      mayModifyItems => $item->{mayModifyItems} ? $JSON::true : $JSON::false,
      mayRemoveItems => $item->{mayRemoveItems} ? $JSON::true : $JSON::false,
      mayDelete => $item->{mayDelete} ? $JSON::true : $JSON::false,
      mayRename => $item->{mayRename} ? $JSON::true : $JSON::false,
    );

    foreach my $key (keys %rec) {
      delete $rec{$key} unless _prop_wanted($args, $key);
    }

    push @list, \%rec;
  }

  $Self->commit();

  my %missingids = %want;

  return ['Addressbook/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_Addressbook_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  # we have no datatype for you yet
  my $newState = "$user->{jhighestmodseq}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jaddressbooks', {}, 'jaddressbookid,jmodseq,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  $Self->commit();

  my @created;
  my @updated;
  my @removed;
  foreach my $item (@$data) {
    if ($item->{jmodseq} > $sinceState) {
      if ($item->{active}) {
        if ($item->{jcreated} <= $sinceState) {
          push @updated, $item->{jaddressbookid};
        }
        else {
          push @created, $item->{jaddressbookid};
        }
      }
      else {
        if ($item->{jcreated} <= $sinceState) {
          push @removed, $item->{jaddressbookid};
        }
        # otherwise never seen
      }
    }
  }

  my @res = (['Addressbook/changes', {
    accountId => $accountid,
    oldState => "$sinceState",
    newState => $newState,
    created => [map { "$_" } @created],
    updated => [map { "$_" } @updated],
    removed => [map { "$_" } @removed],
  }]);

  return @res;
}

sub _contact_match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  # XXX - condition handling code
  if ($condition->{inAddressbooks}) {
    my $match = 0;
    foreach my $id (@{$condition->{inAddressbooks}}) {
      next unless $item->{jaddressbookid} eq $id;
      $match = 1;
    }
    return 0 unless $match;
  }

  return 1;
}

sub _contact_filter {
  my $Self = shift;
  my ($data, $filter, $storage) = @_;
  my @res;
  foreach my $item (@$data) {
    next unless $Self->_contact_match($item, $filter, $storage);
    push @res, $item;
  }
  return \@res;
}

sub api_Contact_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateContact}";

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $data = $Self->{db}->dget('jcontacts', { active => 1 }, 'contactuid,jaddressbookid');

  $data = $Self->_event_filter($data, $args->{filter}, {}) if $args->{filter};

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_]{contactuid} } $start..$end;

  $Self->commit();

  my @res;
  push @res, ['Contact/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_Contact_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContact}";

  #properties: String[] A list of properties to fetch for each message.

  my $data = $Self->{db}->dgetby('jcontacts', 'contactuid', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_ => 1 } keys %$data;
  }

  my @list;
  foreach my $id (keys %want) {
    next unless $data->{$id};
    delete $want{$id};

    my $item = decode_json($data->{$id}{payload});

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    $item->{id} = $id;

    push @list, $item;
  }
  $Self->commit();

  my %missingids = %want;

  return ['Contact/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_Contact_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContact}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jcontacts', { jmodseq => ['>', $args->{sinceState}] }, 'contactuid,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }
  $Self->commit();

  my @created;
  my @updated;
  my @removed;

  foreach my $row (@$data) {
    if ($row->{active}) {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @updated, $row->{contactuid};
      }
      else {
        push @created, $row->{contactuid};
      }
    }
    else {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @removed, $row->{contactuid};
      }
      # otherwise never seen
    }
  }

  my @res;
  push @res, ['Contact/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    created => [map { "$_" } @created],
    updated => [map { "$_" } @updated],
    removed => [map { "$_" } @removed],
  }];

  return @res;
}

sub api_ContactGroup_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContactGroup}";

  #properties: String[] A list of properties to fetch for each message.

  my $data = $Self->{db}->dgetby('jcontactgroups', 'groupuid', { active => 1 });

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = map { $_ => 1 } keys %$data;
  }

  my @list;
  foreach my $id (keys %want) {
    next unless $data->{$id};
    delete $want{$id};

    my $item = {};
    $item->{id} = $id;

    if (_prop_wanted($args, 'name')) {
      $item->{name} = $data->{$id}{name};
    }

    if (_prop_wanted($args, 'contactIds')) {
      $item->{contactIds} = $Self->{db}->dgetcol('jcontactgroupmap', { groupuid => $id }, 'contactuid');
    }

    push @list, $item;
  }
  $Self->commit();

  my %missingids = %want;

  return ['ContactGroup/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_ContactGroup_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateContactGroup}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $args->{sinceState} <= $user->{jdeletedmodseq});

  my $sql = "SELECT groupuid,active FROM jcontactgroups WHERE jmodseq > ?";

  my $data = $Self->{db}->dget('jcontactgroups', { jmodseq => ['>', $args->{sinceState}] }, 'groupuid,active,jcreated');

  if ($args->{maxChanges} and @$data > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]);
  }

  my @created;
  my @updated;
  my @removed;

  foreach my $row (@$data) {
    if ($row->{active}) {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @updated, $row->{groupuid};
      }
      else {
        push @created, $row->{groupuid};
      }
    }
    else {
      if ($row->{jcreated} <= $args->{sinceState}) {
        push @removed, $row->{groupuid};
      }
      # otherwise never seen
    }
  }
  $Self->commit();

  my @res;
  push @res, ['ContactGroup/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    created => [map { "$_" } @created],
    updated => [map { "$_" } @updated],
    removed => [map { "$_" } @removed],
  }];

  return @res;
}

sub api_ContactGroup_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  $Self->{db}->sync_addressbooks();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $oldState = "$user->{jstateContactGroup}";
  $Self->commit();

  ($created, $notCreated) = $Self->{db}->create_contact_groups($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_ContactGroup_get');
  ($updated, $notUpdated) = $Self->{db}->update_contact_groups($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_contact_groups($destroy);

  # XXX - cheap dumb racy version
  $Self->{db}->sync_addressbooks();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $newState = "$user->{jstateContactGroup}";
  $Self->commit();

  my @res;
  push @res, ['ContactGroup/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_Contact_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  $Self->{db}->sync_addressbooks();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $oldState = "$user->{jstateContact}";
  $Self->commit();

  ($created, $notCreated) = $Self->{db}->create_contacts($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_Contact_get');
  ($updated, $notUpdated) = $Self->{db}->update_contacts($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_contacts($destroy);

  # XXX - cheap dumb racy version
  $Self->{db}->sync_addressbooks();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $newState = "$user->{jstateContact}";
  $Self->commit();

  my @res;
  push @res, ['Contact/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_CalendarEvent_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  $Self->{db}->sync_calendars();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $oldState = "$user->{jstateCalendarEvent}";
  $Self->commit();

  ($created, $notCreated) = $Self->{db}->create_calendar_events($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_CalendarEvent_get');
  ($updated, $notUpdated) = $Self->{db}->update_calendar_events($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_calendar_events($destroy);

  # XXX - cheap dumb racy version
  $Self->{db}->sync_calendars();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $newState = "$user->{jstateCalendarEvent}";
  $Self->commit();

  my @res;
  push @res, ['CalendarEvent/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub api_Calendar_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  $Self->{db}->sync_calendars();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $oldState = "$user->{jstateCalendar}";
  $Self->commit();

  ($created, $notCreated) = $Self->{db}->create_calendars($create);
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_Calendar_get');
  ($updated, $notUpdated) = $Self->{db}->update_calendars($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_calendars($destroy);

  # XXX - cheap dumb racy version
  $Self->{db}->sync_calendars();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $newState = "$user->{jstateCalendar}";
  $Self->commit();

  my @res;
  push @res, ['Calendar/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  return @res;
}

sub _mk_submission_sort {
  my $items = shift // [];
  return undef unless ref($items) eq 'ARRAY';
  my @res;
  foreach my $item (@$items) { 
    return undef unless defined $item;
    my ($field, $order) = split / /, $item;

    # invalid order
    return undef unless ($order eq 'asc' or $order eq 'desc');

    if ($field eq 'emailId') {
      push @res, "msgid $order";
    }
    elsif ($field eq 'threadId') {
      push @res, "thrid $order";
    }
    elsif ($field eq 'sentAt') {
      push @res, "sentat $order";
    }
    else {
      return undef; # invalid sort
    }
  }
  push @res, 'jsubid asc';
  return join(', ', @res);
}

sub _submission_filter {
  my $Self = shift;
  my $data = shift;
  my $filter = shift;
  my $storage = shift;

  if ($filter->{emailIds}) {
    return 0 unless grep { $_ eq $data->[2] } @{$filter->{emailIds}};
  }
  if ($filter->{threadIds}) {
    return 0 unless grep { $_ eq $data->[1] } @{$filter->{threadIds}};
  }
  if ($filter->{undoStatus}) {
    return 0 unless $filter->{undoStatus} eq 'final';
  }
  if ($filter->{before}) {
    my $time = str2time($filter->{before});
    return 0 unless $data->[3] < $time;
  }
  if ($filter->{after}) {
    my $time = str2time($filter->{after});
    return 0 unless $data->[3] >= $time;
  }

  # true if submitted
  return 1;
}

sub api_EmailSubmission_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateEmailSubmission}";

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $sort = _mk_submission_sort($args->{sort});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $sort;

  my $data = $dbh->selectall_arrayref("SELECT jsubid,thrid,msgid,sendat FROM jsubmission WHERE active = 1 ORDER BY $sort");

  $data = $Self->_submission_filter($data, $args->{filter}, {}) if $args->{filter};
  my $total = scalar(@$data);

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @list = map { $data->[$_] } $start..$end;

  $Self->commit();

  my @res;

  my $subids = [ map { "$_->[0]" } @list ];
  push @res, ['EmailSubmission/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    canCalculateChanges => $JSON::true,
    position => $start,
    total => $total,
    ids => $subids,
  }];

  return @res;
}

sub api_EmailSubmission_queryChanges {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = "$user->{jstateEmailSubmission}";
  my $sinceQueryState = $args->{sinceQueryState};

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceQueryState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    if ($user->{jdeletedmodseq} and $sinceQueryState <= $user->{jdeletedmodseq});

  #properties: String[] A list of properties to fetch for each message.

  my $sort = _mk_submission_sort($args->{sort});
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $sort;

  my $data = $dbh->selectall_arrayref("SELECT jsubid,thrid,msgid,sendat,jmodseq,active FROM jsubmission ORDER BY $sort");

  $data = $Self->_submission_filter($data, $args->{filter}, {}) if $args->{filter};
  my $total = scalar(@$data);

  $Self->commit();

  my @added;
  my @removed;

  my $index = 0;
  foreach my $item (@$data) {
    if ($item->[4] <= $sinceQueryState) {
      $index++ if $item->[5];
      next;
    }
    # changed
    push @removed, "$item->[0]";
    next unless $item->[5];
    push @added, { id => "$item->[0]", index => $index };
    $index++;
  }

  return ['EmailSubmission/queryChanges', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    oldQueryState => $sinceQueryState,
    newQueryState => $newQueryState,
    total => $total,
    removed => \@removed,
    added => \@added,
  }];
}

sub api_EmailSubmission_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateEmailSubmission}";

  return $Self->_transError(['error', {type => 'invalidArguments'}])
    unless $args->{ids};
  #properties: String[] A list of properties to fetch for each message.

  my %seenids;
  my %missingids;
  my @list;
  foreach my $subid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$subid};
    $seenids{$subid} = 1;
    my $data = $Self->{db}->dgetone('jsubmission', { jsubid => $subid });
    unless ($data) {
      $missingids{$subid} = 1;
      next;
    }

    my $thrid = $Self->{db}->dgetfield('jmessages', { msgid => $data->{msgid} }, 'thrid');

    my $item = {
      id => $subid,
      identityId => $data->{identity},
      emailId => $data->{msgid},
      threadId => $thrid,
      envelope => $data->{envelope} ? decode_json($data->{envelope}) : undef,
      sendAt => JMAP::EmailObject::isodate($data->{sendat}),
      undoStatus => $data->{status},
      deliveryStatus => undef,
      dsnBlobIds => [],
      mdnBlobIds => [],
    };

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    push @list, $item;
  }

  $Self->commit();

  return ['EmailSubmission/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

sub api_EmailSubmission_changes {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = "$user->{jstateEmailSubmission}";

  my $sinceState = $args->{sinceState};
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if not $args->{sinceState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}])
    if ($user->{jdeletedmodseq} and $sinceState <= $user->{jdeletedmodseq});

  my $data = $dbh->selectall_arrayref("SELECT jsubid,thrid,msgid,sendat,jmodseq,active,jcreated FROM jsubmission WHERE jmodseq > ? ORDER BY jmodseq ASC", {}, $sinceState);

  $Self->commit();

  my $hasMore = 0;
  if ($args->{maxChanges} and $#$data >= $args->{maxChanges}) {
    $#$data = $args->{maxChanges} - 1;
    $newState = "$data->[-1][4]";
    $hasMore = 1;
  }

  my @created;
  my @updated;
  my @removed;

  foreach my $item (@$data) {
    # changed
    if ($item->[5]) {
      if ($item->[6] <= $args->{sinceState}) {
        push @updated, "$item->[0]";
      }
      else {
        push @created, "$item->[0]";
      }
    }
    else {
      if ($item->[6] <= $args->{sinceState}) {
        push @removed, "$item->[0]";
      }
      # otherwise never seen
    }
  }

  my @res;
  push @res, ['EmailSubmission/changes', {
    accountId => $accountid,
    oldState => $sinceState,
    newState => $newState,
    hasMoreChanges => $hasMore ? $JSON::true : $JSON::false,
    created => \@created,
    updated => \@updated,
    removed => \@removed,
  }];

  return @res;
}

sub api_EmailSubmission_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];
  my $toUpdate = $args->{onSuccessUpdateEmail} || {};
  my $toDestroy = $args->{onSuccessDestroyEmail} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  # TODO: need to support ifInState for this sucker

  my %updateEmails;
  my @destroyEmails;

  my $scoped_lock = $Self->{db}->begin_superlock();

  # make sure our DB is up to date
  $Self->{db}->sync_folders();

  $Self->{db}->begin();
  my $user = $Self->{db}->get_user();
  $oldState = "$user->{jstateEmailSubmission}";
  $Self->{db}->commit();

  ($created, $notCreated) = $Self->{db}->create_submissions($create, sub { $Self->idmap(shift) });
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_EmailSubmission_get');
  ($updated, $notUpdated) = $Self->{db}->update_submissions($update, sub { $Self->idmap(shift) });

  my @possible = ((map { $_->{id} } values %$created), (keys %$updated), @$destroy);

  # we need to convert all the IDs that were successfully created and updated plus any POSSIBLE
  # one that might be deleted into a map from id to messageid - after create and update, but
  # before delete.
  my $result = $Self->api_EmailSubmission_get({ids => \@possible, properties => ['emailId']});
  my %emailIds;
  if ($result->[0] eq 'EmailSubmission/get') {
    %emailIds = map { $_->{id} => $_->{emailId} } @{$result->[1]{list}};
  }

  # we can destroy now that we've read in the messageids of everything we intend to destroy... yay
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_submissions($destroy);

  # OK, we have data on all possible messages that need to be actioned after the messageSubmission
  # changes
  my %allowed = map { $_ => 1 } ((map { $_->{id} } values %$created), (keys %$updated), @$destroyed);

  foreach my $key (keys %$toUpdate) {
    my $id = $Self->idmap($key);
    next unless $allowed{$id};
    $updateEmails{$emailIds{$id}} = $toUpdate->{$key};
  }
  foreach my $key (@$toDestroy) {
    my $id = $Self->idmap($key);
    next unless $allowed{$id};
    push @destroyEmails, $emailIds{$id};
  }

  $Self->{db}->begin();
  $user = $Self->{db}->get_user();
  $newState = "$user->{jstateEmailSubmission}";
  $Self->{db}->commit();

  my @res;
  push @res, ['EmailSubmission/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => $created,
    notCreated => $notCreated,
    updated => $updated,
    notUpdated => $notUpdated,
    destroyed => $destroyed,
    notDestroyed => $notDestroyed,
  }];

  if (%updateEmails or @destroyEmails) {
    push @res, $Self->api_Email_set({update => \%updateEmails, destroy => \@destroyEmails});
  }

  return @res;
}

sub dummy_node_matches {
  my $filter = shift;
  my $node = shift;

  return 1 unless $filter;
  return 1 unless $filter->{parentIds};

  foreach my $parentId (@{$filter->{parentIds}}) {
    if (not defined $parentId) {
      return 1 if not defined $node->{parentId};
    }
    else {
      return 1 if (defined $node->{parentId} and $parentId eq $node->{parentId});
    }
  }

  return 0;
}

sub dummy_storage_node_data {
  my $time = '2018-02-01T00:00:00Z';
  my @data = (
    {
      id => 'root',
      parentId => undef,
      blobId => undef,
      name => '/',
      created => $time,
      modified => $time,
      size => 0,
      type => undef,
      mayUpdate => $JSON::true,
      mayRename => $JSON::true,
      mayDelete => $JSON::true,
      mayCreateChild => $JSON::true,
      mayAddItems => $JSON::true,
      mayReadItems => $JSON::true,
      mayRemoveItems => $JSON::true,
    },
    {
      id => 'trash',
      parentId => undef,
      blobId => undef,
      name => 'Trash',
      created => $time,
      modified => $time,
      size => 0,
      type => undef,
      mayUpdate => $JSON::true,
      mayRename => $JSON::true,
      mayDelete => $JSON::true,
      mayCreateChild => $JSON::true,
      mayAddItems => $JSON::true,
      mayReadItems => $JSON::true,
      mayRemoveItems => $JSON::true,
    },
  );

  return @data;
}

sub api_StorageNode_query {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newQueryState = 'dummy';

  my $data = [grep { dummy_node_matches($args->{filter}, $_) } dummy_storage_node_data()];

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments'}])
    if $start < 0;

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_]{id} } $start..$end;

  $Self->commit();

  return ['StorageNode/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    queryState => $newQueryState,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];
}

sub api_StorageNode_get {
  my $Self = shift;
  my $args = shift;

  $Self->begin();
  my $dbh = $Self->{db}->dbh();

  my $user = $Self->{db}->get_user();
  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  my $newState = 'dummy';

  #properties: String[] A list of properties to fetch for each message.

  my $data = { map { $_->{id} => $_ } dummy_storage_node_data() };

  my %want;
  if ($args->{ids}) {
    %want = map { $Self->idmap($_) => 1 } @{$args->{ids}};
  }
  else {
    %want = %$data;
  }

  my @list;
  foreach my $id (keys %want) {
    next unless $data->{$id};
    delete $want{$id};

    my $item = $data->{$id};

    foreach my $key (keys %$item) {
      delete $item->{$key} unless _prop_wanted($args, $key);
    }

    $item->{id} = $id;

    push @list, $item;
  }
  $Self->commit();

  my %missingids = %want;

  return ['StorageNode/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}


1;
