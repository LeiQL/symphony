<!-- Code generated by gomarkdoc. DO NOT EDIT -->

# expectations

```go
import "github.com/eclipse-symphony/symphony/packages/testutils/expectations"
```

## Index

- [type AllExpectation](<#AllExpectation>)
  - [func All\(expectations ...types.Expectation\) \*AllExpectation](<#All>)
  - [func \(e \*AllExpectation\) Description\(\) string](<#AllExpectation.Description>)
  - [func \(e \*AllExpectation\) Id\(\) string](<#AllExpectation.Id>)
  - [func \(e \*AllExpectation\) Verify\(c context.Context\) error](<#AllExpectation.Verify>)
  - [func \(a \*AllExpectation\) WithCaching\(\) \*AllExpectation](<#AllExpectation.WithCaching>)
- [type AnyExpectation](<#AnyExpectation>)
  - [func Any\(expectations ...types.Expectation\) \*AnyExpectation](<#Any>)
  - [func \(e \*AnyExpectation\) Description\(\) string](<#AnyExpectation.Description>)
  - [func \(e \*AnyExpectation\) Id\(\) string](<#AnyExpectation.Id>)
  - [func \(e \*AnyExpectation\) Verify\(c context.Context\) error](<#AnyExpectation.Verify>)


<a name="AllExpectation"></a>
## type [AllExpectation](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=15&lineEnd=21&lineStartColumn=2&lineEndColumn=3>)



```go
type AllExpectation struct {
    // contains filtered or unexported fields
}
```

<a name="All"></a>
### func [All](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=102&lineEnd=102&lineStartColumn=1&lineEndColumn=60>)

```go
func All(expectations ...types.Expectation) *AllExpectation
```

All returns an expectation that is satisfied if all of the given expectations are satisfied.

<a name="AllExpectation.Description"></a>
### func \(\*AllExpectation\) [Description](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=89&lineEnd=89&lineStartColumn=1&lineEndColumn=46>)

```go
func (e *AllExpectation) Description() string
```

Description implements types.Expectation.

<a name="AllExpectation.Id"></a>
### func \(\*AllExpectation\) [Id](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=84&lineEnd=84&lineStartColumn=1&lineEndColumn=37>)

```go
func (e *AllExpectation) Id() string
```

Id implements types.Expectation.

<a name="AllExpectation.Verify"></a>
### func \(\*AllExpectation\) [Verify](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=50&lineEnd=50&lineStartColumn=1&lineEndColumn=57>)

```go
func (e *AllExpectation) Verify(c context.Context) error
```

Verify implements types.Expectation.

<a name="AllExpectation.WithCaching"></a>
### func \(\*AllExpectation\) [WithCaching](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=95&lineEnd=95&lineStartColumn=1&lineEndColumn=55>)

```go
func (a *AllExpectation) WithCaching() *AllExpectation
```

WithCaching returns a new expectation that caches the result of each expectation successfull expectation so that it is not verified again in future calls to Verify.

<a name="AnyExpectation"></a>
## type [AnyExpectation](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=22&lineEnd=26&lineStartColumn=2&lineEndColumn=3>)



```go
type AnyExpectation struct {
    // contains filtered or unexported fields
}
```

<a name="Any"></a>
### func [Any](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=111&lineEnd=111&lineStartColumn=1&lineEndColumn=60>)

```go
func Any(expectations ...types.Expectation) *AnyExpectation
```

Any returns an expectation that is satisfied if any of the given expectations is satisfied.

<a name="AnyExpectation.Description"></a>
### func \(\*AnyExpectation\) [Description](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=74&lineEnd=74&lineStartColumn=1&lineEndColumn=46>)

```go
func (e *AnyExpectation) Description() string
```

Description implements types.Expectation.

<a name="AnyExpectation.Id"></a>
### func \(\*AnyExpectation\) [Id](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=79&lineEnd=79&lineStartColumn=1&lineEndColumn=37>)

```go
func (e *AnyExpectation) Id() string
```

Id implements types.Expectation.

<a name="AnyExpectation.Verify"></a>
### func \(\*AnyExpectation\) [Verify](<https://dev.azure.com/msazure/One/_git/symphony?path=packages%2Ftestutils%2Fexpectations%2Fexpectation.go&version=GBmain&lineStyle=plain&line=35&lineEnd=35&lineStartColumn=1&lineEndColumn=57>)

```go
func (e *AnyExpectation) Verify(c context.Context) error
```

Verify implements types.Expectation.

Generated by [gomarkdoc](<https://github.com/princjef/gomarkdoc>)