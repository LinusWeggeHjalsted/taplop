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
        SoundControllerScript.Instance.PlayMenuSound(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
        if (newGameMenu == null)
        {
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
        newGameMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/New Game Menu");
    }
}
