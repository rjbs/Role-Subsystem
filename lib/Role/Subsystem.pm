package Role::Subsystem;
use MooseX::Role::Parameterized;
# ABSTRACT: a parameterized role for object subsystems, helpers, and delegates

=head1 SYNOPSIS

You write this subsystem:

  package Account::SettingsManager;
  use Moose;
  use Account;

  with 'Role::Subsystem' => {
    ident  => 'acct-settings-mgr',
    type   => 'Account',
    what   => 'account',
    getter => sub { Account->retrieve_by_id( $_[0] ) },
  };

  sub do_stuff {
    my ($self) = @_;

    $self->account->xyzzy;
  }

...and then you can say:

  my $settings_mgr = Account::SettingsManager->for_account($account);

  printf "We got the settings manager for account %s\n",
    $settings_mgr->account_id;

  $settings_mgr->do_stuff;

=head1 DESCRIPTION

Role::Subsystem is a L<parameterized role|MooseX::Role::Parameterized>.  It's
meant to simplify creating classes that encapsulate specific parts of the
business logic related to parent classes.  As in the L<synopsis|/SYNOPSIS>
above, it can be used to write "helpers."  The subsystems it creates must have
a reference to a parent object, which might be referenced by id or with an
actual object reference.  Role::Subsystem tries to guarantee that no matter
which kind of reference you have, the other kind can be obtained and stored for
use.

=head1 PARAMETERS

These parameters can be given when including Role::Subsystem; these are in
contrast to the L<attributes|/ATTRIBUTES> and L<methods|/METHODS> below, which
are added to the classe composing this role.

=head2 ident

This is a simple name for the role to use when describing itself in messages.
It is required.

=cut

parameter ident => (isa => 'Str', required => 1);

=head2 what

This is the name of the attribute that will hold the parent object, like the
C<account> in the synopsis above.

This attribute is required.

=cut

parameter what => (
  isa      => 'Str',
  required => 1,
);

=head2 type

This is the type that the C<what> must be.  It may be a stringly Moose type or
an L<MooseX::Types> type.  (Or anything else, right now, but anything else will
probably cause runtime failures or worse.)

This attribute is required.

=cut

parameter type    => (isa => 'Defined', required => 1);

=head2 id_type

This parameter is like C<type>, but is used to check the C<what>'s id,
discussed more below.  If not given, it defaults to C<Defined>.

=cut

parameter id_type => (isa => 'Defined', default => 'Defined');

=head2 id_method

This is the name of a method to call on C<what> to get its id.  It defaults to
C<id>.

=cut

parameter id_method => (isa => 'Str', default => 'id');

=head2 getter

This (optional) attribute supplied a callback that will produce the parent
object from the C<what_id>.

=cut

parameter getter => (
  isa     => 'CodeRef',
);

=head2 weak_ref

If true, when a subsytem object is created with a defined parent object (that
is, a value for C<what>), the reference to the object will be weakened.  This
allows the parent and the subsystem to store references to one another without
creating a problematic circular reference.

If the parent object is subsequently garbage collected, a new value for C<what>
will be retreived and stored, and it will B<not> be weakened.  To allow this,
setting C<weak_ref> to true requires that C<getter> be supplied.

C<weak_ref> is true by default.

=cut

parameter weak_ref => (
  isa     => 'Bool',
  default => 1,
);

role {
  my ($p)  = @_;

  my $what      = $p->what;
  my $ident     = $p->ident;
  my $what_id   = "$what\_id";
  my $getter    = $p->getter;
  my $id_method = $p->id_method;
  my $weak_ref  = $p->weak_ref;

  my $w_pred    = "has_initialized_$what";
  my $wi_pred   = "has_initialized_$what_id";
  my $w_reader  = "_$what";
  my $w_clearer = "_clear_$what";

  confess "cannot use weak references for $ident without a getter"
    if $weak_ref and not $getter;

  has $what => (
    is        => 'bare',
    reader    => $w_reader,
    isa       => $p->type,
    lazy      => 1,
    predicate => $w_pred,
    clearer   => $w_clearer,
    default   => sub {
      # Basically, this should never happen.  We should not be generating the
      # for_what_id method if there is no getter, and we should be blowing up
      # if produced without a what without a getter.  Still, CYA.
      # -- rjbs, 2010-05-05
      confess "cannot get a $what based on $what_id; no getter" unless $getter;

      $getter->( $_[0]->$what_id );
    },
  );

  if ($weak_ref) {
    method $what => sub {
      my ($self) = @_;
      my $value = $self->$w_reader;
      return $value if defined $value;
      $self->$w_clearer;
      return $self->$w_reader;
    };
  } else {
    my $reader = "_$what";
    method $what => sub { $_[0]->$reader },
  }

  has $what_id => (
    is   => 'ro',
    isa  => $p->id_type,
    lazy => 1,
    predicate => $wi_pred,
    default   => sub { $_[0]->$what->$id_method },
  );

  method BUILD => sub {};

  after BUILD => sub {
    my ($self) = @_;

    # So, now we protect ourselves from pathological cases.  These are:
    # 1. neither $what nor $what_id given
    unless ($self->$w_pred or $self->$wi_pred) {
      confess "neither $what nor $what_id given in constructing $ident";
    }

    # 2. both $what and $what_id given, but not matching
    if (
      $self->$w_pred and $self->$wi_pred
      and $self->$what->$id_method ne $self->$what_id
    ) {
      confess "the result of $what->$id_method is not equal to the $what_id"
    }

    # 3. only $what_id given, but no getter
    if ($self->$wi_pred and ! $self->$w_pred and ! $getter) {
      confess "can't build $ident with only $what_id; no getter";
    }

    if ($weak_ref) {
      # We get the id immediately, if we have a weak ref, on the assumption
      # that if the ref expires, we will need the id for the getter
      # to function. -- rjbs, 2010-05-05
      $self->$what_id unless $self->$wi_pred;

      # We only *really* weaken this if we're starting off with an object from
      # outside, because if we got the object from our getter, nothing else is
      # likely to be holding a reference to it. -- rjbs, 2010-05-05
      Scalar::Util::weaken $self->{$what} if $self->$w_pred;
    }
  };

  method "for_$what" => sub {
    my ($class, $entity, $arg) = @_;
    $arg ||= {};

    $class->new({
      %$arg,
      $what => $entity,
    });
  };

  if ($getter) {
    method "for_$what_id" => sub {
      my ($class, $id, $arg) = @_;
      $arg ||= {};

      $class->new({
        %$arg,
        $what_id => $id,
      });
    };
  }
};

=head1 ATTRIBUTES

The following attributes are added classes composing Role::Subsystem.

=head2 $what

This will refer to the parent object of the subsystem.  It will be a value of
the C<type> type defined when parameterizing Role::Subsystem.  It may be lazily
computed if it was not supplied during creation or if the initial value was
weak and subsequently garbage collected.

If the value of C<what> when parameterizing Role::Subsystem was C<account>,
that will be the name of this attribute, as well as the method used to read it.

=head2 $what_id

This method gets the id of the parent object.  It will be a defined value of
the C<id_type> provided when parameterizing Role::Subsystem.  It may be lazily
computed by calling the C<id_method> on C<what> as needed.

=head1 METHODS

=head2 for_$what

  my $settings_mgr = Account::SettingsManager->for_account($account);

This is a convenience constructor, returning a subsystem object for the given
C<what>.

=head2 for_$what_id

  my $settings_mgr = Account::SettingsManager->for_account_id($account_id);

This is a convenience constructor, returning a subsystem object for the given
C<what_id>.

=cut
