#!/usr/bin/perl
use strict;
use warnings;

use Net::LDAP;
use Getopt::Long;
use Data::Dumper;
use JSON;
use REST::Client;
use WebService::DataDog;


## Definitions
my ($submitreport);
my $opts = GetOptions(
  'submitreport' => \$submitreport,
  'help!' => sub{&usage},
);

## Read Config.
my $config_file = "/etc/zreport/zreport.cfg";
my @requiredparameters = ('APIKEY','APPKEY','SERVICE');

##Check if config file exists.
if ( ! -e $config_file )
{
  print "Didn't find config file $config_file\n\n";
  &usage;
}

open(CONFIG,"<$config_file");
my ($var, $value, %config, @allowed_groups);
while (<CONFIG>) {
  chomp;                  # no newline
  s/#.*//;                # no comments
  s/^\s+//;               # no leading white
  s/\s+$//;               # no trailing white
  next unless length;     # anything left?
  ($var, $value) = split(/\s*=\s*/, $_, 2);
  $value =~ s/'|"//g;
  $config{$var} = $value;
}
close CONFIG;

##Check required parameters.
for my $parameter( @requiredparameters )
{
  if ( ! $config{$parameter} && $submitreport )
  {
    print "Required parameter not setted: $parameter. Please set the following parameters at $config_file in order to work properly :\n@requiredparameters\n\n";
    &usage;
  }
}


# Create an object to communicate with DataDog
my $datadog = WebService::DataDog->new(
  api_key         => $config{'APIKEY'},
  application_key => $config{'APPKEY'}
);

# If at least one flag match, the version will be considered
my %zimbraEditionsFlags = (
  'professional' => {
    'zimbraFeatureMAPIConnectorEnabled' => 'TRUE',
    'zimbraArchiveEnabled' => 'TRUE',
    'zimbraFeatureMobileSyncEnabled' => 'TRUE',
  },
  'standard' => {
    'zimbraFeatureConversationsEnabled' =>  'TRUE',
    'zimbraFeatureTaggingEnabled' =>  'TRUE',
    'zimbraAttachmentsIndexingEnabled'  =>  'TRUE',
    'zimbraFeatureViewInHtmlEnabled'  =>  'TRUE',
    'zimbraFeatureGroupCalendarEnabled' =>  'TRUE',
    'zimbraFreebusyExchangeURL' =>  'TRUE',
    'zimbraFeatureTasksEnabled' =>  'TRUE',
    'zimbraFeatureBriefcasesEnabled'  =>  'TRUE',
    'zimbraFeatureSMIMEEnabled' =>  'TRUE',
    'zimbraFeatureVoiceEnabled' =>  'TRUE',
    'zimbraFeatureSharingEnabled' => 'TRUE',
  },
  'bemail_plus' => {
    'zimbraFeatureCalendarEnabled' => 'TRUE',
    'zimbraFeatureManageZimlets' => 'TRUE'
  },
  'bemail' => {
  }
);

# From the most specific going down
my @zimbraEditionsHierarchy = ('professional', 'standard', 'bemail_plus', 'bemail');

## ACTION
my $ldapProp = &getLdapProperties;
my $zCos = &ldapSearch('objectClass=zimbraCOS','',$ldapProp,'cn');
my $zData = &getAccountsCosAndType ($ldapProp, $zCos, \%zimbraEditionsFlags, \@zimbraEditionsHierarchy);

print "Getting zimbra hostname...\n";
my $zcs_hostname = `su zimbra -c "/opt/zimbra/bin/zmhostname"`;

# For metrics functions, first build a metrics object
my $metric = $datadog->build('Metric');
my $msg;
for my $edition (keys(%zimbraEditionsFlags))
{
  # set 0 if edition doesn't exist
  $zData->{edition}{$edition} = 0 if ( ! $zData->{edition}{$edition});
  $msg .= "$edition: " . $zData->{edition}{$edition} . "\n";

  print "posting metric $edition: $zData->{edition}{$edition}\n";
  $metric->emit(
    name        => 'inova.zreport',
    type        => 'gauge',  # Optional - gauge|counter. Default=gauge.
    value       => $zData->{edition}{$edition}, # For posting a single data point, time 'now'
    host        => $zcs_hostname,     # Optional - host that produced the metric
    tags        => ["type:$edition", "service:$config{SERVICE}"],     # Optional - tags associated with the metric
  );

}

# For event functions, first build an event object
my $event = $datadog->build('Event');

# To post a new event to the event stream
print "creating datadog event\n";
$event->create(
  title            => "zreport: $config{SERVICE}",
  text             => "Server $zcs_hostname reported:\n\n" . Dumper(\%{$zData}) ,  # Body/Description of the event.
  tags             => ["service:$config{SERVICE}", "report:zimbrareport"],    # Optional - tags to apply to event (easy to search by)
  alert_type       => 'success',  # Optional. error|warning|info|success
  source_type_name => 'my apps'
);

print "finished.\n";
# SUBs
sub getLdapProperties
{
  my %ldapProp;

  my $cmd = '/opt/zimbra/bin/zmlocalconfig -s | grep ldap';
  print "Getting Zimbra LDAP properties ($cmd).\n";
  my @output = map {s/^\s+|\s+$//g; $_} `$cmd`;

  for my $entry (@output)
  {
    $entry =~ m/(.+?)(?:\s\=\s)(.+)/o;
    $ldapProp{$1} = $2;
  }

  return \%ldapProp;
}

sub getZimbraEdition
{
  my $zFlags = shift;
  my $zimbraEditionsFlags = shift;
  my $zimbraEditionsHierarchy = shift;

  for my $edition (@{$zimbraEditionsHierarchy})
  {
    for my $flag (keys %{$zimbraEditionsFlags->{$edition}})
    {
      if (exists ($zFlags->{$flag}) && $zFlags->{$flag} eq $zimbraEditionsFlags->{$edition}->{$flag})
      {
        #print "Matched $flag = $zFlags->{$flag}, so edition is $edition\n";
        return $edition;
      }
    }
  }

  # If nothing matches, it's the last in the hierarchy
  return $zimbraEditionsHierarchy[-1];
}


sub getZimbraEditionsAttrs
{
  my $zimbraEditionsFlags = shift;
  my @attrs;

  for my $entry (values %{$zimbraEditionsFlags})
  {
    for my $flag (keys %{$entry})
    {
      push (@attrs, $flag);
    }
  }

  return \@attrs;
}

sub getAccountFlags
{
  my $cosObj = shift;
  my $entryObj = shift;
  my $zimbraEditionsFlags = shift;

  my %zFlags = %{$cosObj};
  my $zAttrs = &getZimbraEditionsAttrs ($zimbraEditionsFlags);

  for my $attr (@{$zAttrs})
  {
    if ($entryObj->{$attr})
    {
      # Overload COS entries with account specific entries
      $zFlags{$attr} = $entryObj->{$attr};
      #print "Overloaded: $attr\n";
    }
  }

  return \%zFlags;
}


sub ldapSearch{
        my $ldap_filter = shift; my @ldap_attrs = shift; my $ldapProp = shift; my $pK = shift;

        # LDAP query is way faster than zmprov getAccount by each one
        my $ldap = Net::LDAP->new($ldapProp->{ldap_host}) || die "$@";
        $ldap->bind($ldapProp->{zimbra_ldap_userdn} , password => $ldapProp->{zimbra_ldap_password});


        my $ldap_search = $ldap->search (
                        scope => 'sub',
                        filter => $ldap_filter,
                        attrs => @ldap_attrs,
                        );


        # if error
        $ldap_search->code && die $ldap_search->error;


  @ldap_attrs = split(/,/, $ldap_attrs[0]) if grep("/\,",@ldap_attrs);


  my %hash_return;

  foreach my $entry ( $ldap_search->entries)
  {
    for my $attr ( @{$entry->{'asn'}{'attributes'}} )
    {
      $hash_return{$entry->get_value($pK)}{$attr->{'type'}} = $entry->get_value($attr->{'type'});
    }


    if ( $entry->get_value('zimbraId') && $entry->get_value('objectClass') eq 'zimbraCOS' )
    {
      $hash_return{$entry->get_value('zimbraId')} = $entry->get_value('cn');
    }


  }

  return \%hash_return;
}




sub getAccountsCosAndType
{
  my $ldapProp = shift;
  my $zCos = shift;
  my $zimbraEditionsFlags = shift;
  my $zimbraEditionsHierarchy = shift;

  my %data;

  print "Getting users...\n";
  my $accountQuery = '(&(objectClass=zimbraAccount)(!(objectClass=zimbraCalendarResource))(!(zimbraIsSystemResource=TRUE)))';
  my $zAccounts = &ldapSearch($accountQuery,'',$ldapProp,'zimbraMailDeliveryAddress');

  print "Getting users's attributes...\n";
  foreach my $zId ( keys(%{$zAccounts}) )
  {


    next if ( !$zAccounts->{$zId}{'zimbraMailDeliveryAddress'} && !$zAccounts->{$zId}{'zimbraCOSId'} );

    my $cos = 'default';
    $cos = $zCos->{$zAccounts->{$zId}{'zimbraCOSId'}} if ( $zAccounts->{$zId}{'zimbraCOSId'} && $zCos->{$zAccounts->{$zId}{'zimbraCOSId'}} );

    my @email = split (/\@/, $zAccounts->{$zId}{'zimbraMailDeliveryAddress'});

    my %info = (
      account => $email[0],
      domain => $email[1],
      cos => $cos,
      accountType => &getZimbraEdition(&getAccountFlags ($zCos->{$cos}, $zAccounts->{$zId}, $zimbraEditionsFlags), $zimbraEditionsFlags, $zimbraEditionsHierarchy)
    );

    # debug
    #$data{$zAccounts->{$zId}{'zimbraMailDeliveryAddress'}} = \%info;
    #$data{'zimbraReport'}{$data{$zAccounts->{$zId}{'zimbraMailDeliveryAddress'}}{domain}}{$data{$zAccounts->{$zId}{'zimbraMailDeliveryAddress'}}{accountType}}++;
    #$data{'zimbraReport'}{$data{$zAccounts->{$zId}{'zimbraMailDeliveryAddress'}}{domain}}{domain}=$email[1];

                $data{'edition'}{$info{accountType}}++;

        }


  return \%data;
}



sub usage{
        print   "Zimbra Report Account Edition.

                usage: $0 <options>

                        -h,--help                   Displays this help message.
      -s,--submitreport     Send report to Inova API.
               \n";

        exit 1;
}