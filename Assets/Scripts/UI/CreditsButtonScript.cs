using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class CreditsButtonScript : MonoBehaviour, IPointerDownHandler
{
    Button button;
    GameObject creditsMenuPrefab;
    GameObject creditsMenu;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayMenuSound();
        if (creditsMenu == null)
        {
            GameObject newGameMenu = GameObject.Find("New Game Menu(Clone)");
            if (newGameMenu != null)
            {
                DestroyImmediate(newGameMenu);
            }
            creditsMenu = Instantiate(creditsMenuPrefab, this.transform.parent.parent);
        }
        else
        {
            DestroyImmediate(creditsMenu);
        }
    }

    void Awake()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        creditsMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/Credits Menu");
    }
}
