using UnityEngine;
using UnityEngine.UI;
using System;
using System.IO;

public class NewGameButtonScript : MonoBehaviour
{
    Button button;
    GameObject newGameMenuPrefab;
    GameObject newGameMenu;

    public void OnActivate()
    {
        if (newGameMenu == null)
        {
            // close Support Menu if it's open
            GameObject supportMenu = GameObject.Find("Support Menu(Clone)");
            if (supportMenu != null)
            {
                Destroy(supportMenu);
            }
            newGameMenu = Instantiate(newGameMenuPrefab, this.transform.parent.parent);
        }
        else
        {
            DestroyImmediate(newGameMenu);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        newGameMenuPrefab = Resources.Load<GameObject>("Prefabs/New Game Menu");
    }
}
