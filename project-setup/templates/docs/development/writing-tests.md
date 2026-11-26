# What a Test Checks

A test earns its run time by failing when the behaviour its name states breaks, and only then. A test that fails when someone adds an unrelated feature is a _change detector_: it catches no bug, and it costs every later change a fix. Read this before you write, change, or delete a test.

Structure every test as Given/When/Then with the `gwt-tester` skill.

## Assert what the name says

Each `Then` checks the claim in its own name, and nothing that another feature owns.

| The test says                        | Assert                                              | Not                                    |
| ------------------------------------ | --------------------------------------------------- | -------------------------------------- |
| Save is just before Cancel           | the index of `Save` is the index of `Cancel` minus 1 | the whole toolbar equals a fixed list  |
| The menu has Rename, then Delete     | both are in it, Rename first                         | the menu holds exactly three items     |
| A viewer gets no Delete              | the viewer's items don't contain `Delete`            | the viewer's whole menu                |

Use a contains check, an order comparison, or a filter to the items under test before an equality check.

## Pin a whole list only where the list is the contract

Some lists must fail on any addition, because an addition needs a person to review it. Pin these exactly, and say why in the test's name or a comment, so the agent whose change fails it reviews the addition and doesn't just append it:

- what a role may see or do, where an extra item could expose something;
- what an API or an agent tool surface offers;
- the fields a response or an export returns, where an extra one could leak data;
- the inventory of secrets, bindings, and hosts a deploy needs.

## Delete the tests of a removed feature

When you remove a feature, delete its tests. A new test that the removed thing stays gone guards nothing. The exception is an absence that protects privacy, access, billing, or an owner decision in [product-decisions.md](../product-decisions.md): that check belongs with the rule, named for the rule.

## Run the tests your change could fail

Before you add an item beside others, search the tests for the names of its neighbours and run every file that names them.
