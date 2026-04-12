using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using System;
using System.IO;

public class NewGameButtonScript : MonoBehaviour, IPointerDownHandler
{
    Button button;
    GameObject newGameMenuPrefab;
    GameObject newGameMenu;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayMenuSound();
        if (newGameMenu == null)
        {
            GameObject supportMenu = GameObject.Find("Support Menu(Clone)");
            if (supportMenu != null)
            {
                DestroyImmediate(supportMenu);
            }
            GameObject creditsMenu = GameObject.Find("Credits Menu(Clone)");
            if (creditsMenu != null)
            {
                DestroyImmediate(creditsMenu);
            }
            newGameMenu = Instantiate(newGameMenuPrefab, this.transform.parent.parent);
        }
        else
        {
            DestroyImmediate(newGameMenu);
        }
    }

    void Awake()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        newGameMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/New Game Menu");
    }
}
